unit Crash.Upload;

{ Report delivery: a self-contained multipart POST, the background upload
  worker (deletes the report and its .pending marker on success) and the
  bounded startup batch.

  Workers capture only immutable values and never touch reporter state, so
  they stay safe when the reporter is torn down while HTTP is still running;
  an operation lifetime keeps a completion callback from reaching a dead host.

  Copyright (c) 2026 Vizit0r. BSD 2-Clause license (see LICENSE.txt). }

interface

type
  { Completion callback for a background upload. It is queued to the main
    thread; the transport worker never calls host/UI code directly. }
  TCrashUploadCompleteProc = reference to procedure(const ASuccess: Boolean);

  { Transport used by the worker: AReportText is the in-memory text, ABody the
    exact upload body (file bytes). }
  TCrashUploadTransportProc = reference to function(const AUrl, AFieldName,
    AReportText, AFileName: String; const ABody: TArray<Byte>): Boolean;

  { Gate shared by a reporter runtime and its background workers: after
    Deactivate no completion callback is delivered. Reference-counted so a
    worker may outlive the runtime that started it. }
  ICrashOperationLifetime = interface
    function Active: Boolean;
    procedure Deactivate;
  end;

  {$IFDEF AUTOTESTS}
  TCrashAutoTestUploadProc = reference to function(const AUrl, AFieldName,
    AReportText, AFileName: String): Boolean;
  TCrashAutoTestUploadBodyProc = reference to function(const AFileName: String;
    const ABody: TArray<Byte>): Boolean;
  {$ENDIF}

function CrashNewOperationLifetime: ICrashOperationLifetime;

{ Multipart POST of ABody (the file as on disk: UTF-16LE+BOM .el text or .elp
  package bytes). True on HTTP 2xx. Honours CRASH_NO_UPLOAD=1. }
function CrashUploadBody(const AUrl, AFieldName: String;
  const ABody: TArray<Byte>; const AFileName: String): Boolean;
// The same POST for report text held in memory.
function CrashUploadReportText(const AUrl, AFieldName, AReportText,
  AFileName: String): Boolean;

{ Start a background upload of the report at AReportPath (AReportText when the
  file is plain text). Success deletes the report and then its marker. }
function CrashQueueUpload(const AUrl, AFieldName, AReportText,
  AReportPath: String; const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean;
function CrashQueueUploadWithTransport(const AUrl, AFieldName, AReportText,
  AReportPath: String; const ATransport: TCrashUploadTransportProc;
  const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean;
{ Upload previous-run reports one by one on a background thread; each success
  deletes the report and its marker, a failure leaves both for a later boot. }
procedure CrashQueueStartupUploads(const AUrl, AFieldName: String;
  const AFiles: TArray<String>);

{$IFDEF AUTOTESTS}
{ Queue the same transport worker with an injected transport. This avoids a
  live endpoint in state tests while exercising delete/keep and non-blocking
  behavior. }
function CrashAutoTestQueueUpload(const AReportText, AReportPath: String;
  const ATransport: TCrashAutoTestUploadProc;
  const AOnComplete: TCrashUploadCompleteProc = nil): Boolean;
{ The same worker; the transport sees the exact upload body (file bytes). }
function CrashAutoTestQueueUploadBody(const AReportText, AReportPath: String;
  const ATransport: TCrashAutoTestUploadBodyProc): Boolean;
function CrashAutoTestOperationLifetimeGate: Boolean;
{$ENDIF}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.IOUtils,
  System.Net.HttpClient,
  System.Net.Mime,
  System.Net.URLClient,
  Crash.Pending;

type
  TCrashOperationLifetime = class(TInterfacedObject, ICrashOperationLifetime)
  private
    FActive: Integer;
  public
    constructor Create;
    function Active: Boolean;
    procedure Deactivate;
  end;

constructor TCrashOperationLifetime.Create;
begin
  inherited Create;
  FActive := 1;
end;

function TCrashOperationLifetime.Active: Boolean;
begin
  Result := TInterlocked.CompareExchange(FActive, 1, 1) = 1;
end;

procedure TCrashOperationLifetime.Deactivate;
begin
  TInterlocked.Exchange(FActive, 0);
end;

function CrashNewOperationLifetime: ICrashOperationLifetime;
begin
  Result := TCrashOperationLifetime.Create;
end;

function CrashUploadBody(const AUrl, AFieldName: String;
  const ABody: TArray<Byte>; const AFileName: String): Boolean;
// Deliberately touches NO reporter-singleton state: the worker may still be
// running while the singleton is torn down at shutdown.
var
  Client: THTTPClient;
  Form: TMultipartFormData;
  Bytes: TBytes;
  Stream: TBytesStream;
  Resp: IHTTPResponse;
  UploadName, FieldName: String;
begin
  Result := False;
  if AUrl = '' then
    Exit;
  // Test/dev escape: env CRASH_NO_UPLOAD=1 -> skip the POST and keep the file,
  // so a local .el can be read without a network side effect.
  if GetEnvironmentVariable('CRASH_NO_UPLOAD') = '1' then Exit;

  Bytes := ABody;

  // Server-side name = on-disk name, so logs/monitoring keep the context.
  if AFileName <> '' then UploadName := AFileName
  else                    UploadName := 'BugReport.el';

  FieldName := AFieldName;
  if FieldName = '' then FieldName := 'el_upload_file_0';

  Stream := TBytesStream.Create(Bytes);
  try
    Client := THTTPClient.Create;
    try
      Client.ConnectionTimeout := 10000;
      Client.ResponseTimeout := 30000;
      Form := TMultipartFormData.Create(True);
      try
        Form.AddStream(FieldName, Stream, False, UploadName, 'application/octet-stream');
        try
          Resp := Client.Post(AUrl, Form);
          Result := (Resp <> nil) and (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
        except
          // Network errors must not crash the process. The file is on disk, the
          // report isn't lost.
          Result := False;
        end;
      finally
        Form.Free;
      end;
    finally
      Client.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function CrashUploadReportText(const AUrl, AFieldName, AReportText,
  AFileName: String): Boolean;
begin
  Result := CrashUploadBody(AUrl, AFieldName,
    CrashReportUploadBody(AReportText, ''), AFileName);
end;

function CrashQueueUpload(const AUrl, AFieldName, AReportText,
  AReportPath: String; const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean;
begin
  Result := CrashQueueUploadWithTransport(AUrl, AFieldName, AReportText,
    AReportPath, nil, AOnComplete, ALifetime);
end;

function CrashQueueUploadWithTransport(const AUrl, AFieldName, AReportText,
  AReportPath: String; const ATransport: TCrashUploadTransportProc;
  const AOnComplete: TCrashUploadCompleteProc;
  const ALifetime: ICrashOperationLifetime): Boolean;
var
  UploadUrl, UploadField, UploadText, UploadPath: String;
  CompleteProc: TCrashUploadCompleteProc;
  TransportProc: TCrashUploadTransportProc;
  Lifetime: ICrashOperationLifetime;
begin
  Result := False;
  if (ALifetime <> nil) and (not ALifetime.Active) then
    Exit;
  // Capture only immutable values. The worker never dereferences the reporter
  // and therefore remains safe if finalization starts while HTTP is active.
  UploadUrl := AUrl;
  UploadField := AFieldName;
  UploadText := AReportText;
  UploadPath := AReportPath;
  CompleteProc := AOnComplete;
  TransportProc := ATransport;
  Lifetime := ALifetime;
  TThread.CreateAnonymousThread(
    procedure
    var
      Success: Boolean;
      Body: TBytes;
    begin
      Success := False;
      try
        Body := CrashReportUploadBody(UploadText, UploadPath);
        if Assigned(TransportProc) then
          Success := TransportProc(UploadUrl, UploadField, UploadText,
            ExtractFileName(UploadPath), Body)
        else
          Success := CrashUploadBody(UploadUrl, UploadField, Body,
            ExtractFileName(UploadPath));
      except
        // Unreadable package: the report and its marker stay for startup.
      end;
      if Success then
        CrashDeleteReportAndPendingMarker(UploadPath);
      if Assigned(CompleteProc) and
         ((Lifetime = nil) or Lifetime.Active) then
        TThread.ForceQueue(nil,
          procedure
          begin
            if (Lifetime <> nil) and (not Lifetime.Active) then
              Exit;
            try
              CompleteProc(Success);
            except
              // A completion callback cannot affect delivery state.
            end;
          end);
    end).Start;
  Result := True;
end;

procedure CrashQueueStartupUploads(const AUrl, AFieldName: String;
  const AFiles: TArray<String>);
var
  UploadUrl, UploadField: String;
  Files: TArray<String>;
begin
  if Length(AFiles) = 0 then
    Exit;
  UploadUrl := AUrl;
  UploadField := AFieldName;
  Files := Copy(AFiles);
  TThread.CreateAnonymousThread(
    procedure
    var
      I: Integer;
      UpFile, UpText: String;
    begin
      for I := 0 to High(Files) do
      begin
        UpFile := Files[I];
        try
          if CrashIsPackagedReport(UpFile) then
            UpText := ''
          else
            UpText := TFile.ReadAllText(UpFile, TEncoding.Unicode);
          if CrashUploadBody(UploadUrl, UploadField,
               CrashReportUploadBody(UpText, UpFile),
               ExtractFileName(UpFile)) then
            CrashDeleteReportAndPendingMarker(UpFile);
        except
          // Unreadable/upload failure: report and marker stay for a later boot.
        end;
      end;
    end).Start;
end;

{$IFDEF AUTOTESTS}
function CrashAutoTestQueueUpload(const AReportText, AReportPath: String;
  const ATransport: TCrashAutoTestUploadProc;
  const AOnComplete: TCrashUploadCompleteProc): Boolean;
var
  WorkerTransport: TCrashUploadTransportProc;
begin
  Result := False;
  if not Assigned(ATransport) then
    Exit;
  WorkerTransport :=
    function(const AUrl, AFieldName, AText, AFileName: String;
      const ABody: TArray<Byte>): Boolean
    begin
      Result := ATransport(AUrl, AFieldName, AText, AFileName);
    end;
  try
    Result := CrashQueueUploadWithTransport('autotest://upload', 'fixture',
      AReportText, AReportPath, WorkerTransport, AOnComplete, nil);
  except
    // The test observes a failed queue request directly.
  end;
end;

function CrashAutoTestQueueUploadBody(const AReportText, AReportPath: String;
  const ATransport: TCrashAutoTestUploadBodyProc): Boolean;
var
  WorkerTransport: TCrashUploadTransportProc;
begin
  Result := False;
  if not Assigned(ATransport) then
    Exit;
  WorkerTransport :=
    function(const AUrl, AFieldName, AText, AFileName: String;
      const ABody: TArray<Byte>): Boolean
    begin
      Result := ATransport(AFileName, ABody);
    end;
  try
    Result := CrashQueueUploadWithTransport('autotest://upload', 'fixture',
      AReportText, AReportPath, WorkerTransport, nil, nil);
  except
  end;
end;

function CrashAutoTestOperationLifetimeGate: Boolean;
var
  TestResult: Boolean;
begin
  TestResult := False;
  // Unit tests run on a registry worker. Observe ForceQueue from the actual
  // main thread, where CheckSynchronize is legal.
  TThread.Synchronize(nil,
    procedure
    var
      Lifetime: ICrashOperationLifetime;
      Gate, Entered, TransportDone: TEvent;
      CallbackCalled, GateResult: Boolean;
      Deadline: UInt64;
    begin
      Lifetime := TCrashOperationLifetime.Create;
      Gate := TEvent.Create(nil, True, False, '');
      Entered := TEvent.Create(nil, True, False, '');
      TransportDone := TEvent.Create(nil, True, False, '');
      try
        CallbackCalled := False;
        GateResult := Lifetime.Active and CrashQueueUploadWithTransport(
          'autotest://lifetime', 'fixture', 'fixture', 'fixture.el',
          function(const AUrl, AFieldName, AText, AFileName: String;
            const ABody: TArray<Byte>): Boolean
          begin
            Entered.SetEvent;
            Gate.WaitFor(2000);
            TransportDone.SetEvent;
            Result := False;
          end,
          procedure(const ASuccess: Boolean)
          begin
            CallbackCalled := True;
          end,
          Lifetime);
        GateResult := GateResult and (Entered.WaitFor(2000) = wrSignaled);
        Lifetime.Deactivate;
        Gate.SetEvent;
        GateResult := GateResult and (not Lifetime.Active) and
          (TransportDone.WaitFor(2000) = wrSignaled);
        // Give the worker time to cross the post-transport gate and pump the
        // main queue. An incorrectly queued callback becomes observable here.
        Deadline := TThread.GetTickCount64 + 250;
        repeat
          CheckSynchronize(0);
          if CallbackCalled then
            Break;
          TThread.Sleep(5);
        until TThread.GetTickCount64 >= Deadline;
        TestResult := GateResult and (not CallbackCalled);
      finally
        Gate.SetEvent;
        TransportDone.WaitFor(2000);
        TransportDone.Free;
        Entered.Free;
        Gate.Free;
      end;
    end);
  Result := TestResult;
end;
{$ENDIF}

end.
