unit CrashDemo.MainForm;

interface

uses
  System.SysUtils,
  System.Classes,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.StdCtrls,
  FMX.Layouts,
  FMX.ListBox,
  FMX.Memo,
  FMX.ScrollBox,
  FMX.Controls.Presentation,
  CrashDemo.Runtime;

type
  TCrashDemoMainForm = class(TForm)
    RootScroll: TVertScrollBox;
    ContentLayout: TLayout;
    TitleLabel: TLabel;
    ReportDirLabel: TLabel;
    RaiseButton: TButton;
    AccessViolationButton: TButton;
    WorkerButton: TButton;
    StackOverflowButton: TButton;
    FreezeButton: TButton;
    StatusLabel: TLabel;
    StatusMemo: TMemo;
    RefreshButton: TButton;
    ClearButton: TButton;
    FilesLabel: TLabel;
    FileList: TListBox;
    ReportLabel: TLabel;
    ReportMemo: TMemo;
    HeartbeatTimer: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure HeartbeatTimerTimer(Sender: TObject);
    procedure RaiseButtonClick(Sender: TObject);
    procedure AccessViolationButtonClick(Sender: TObject);
    procedure WorkerButtonClick(Sender: TObject);
    procedure StackOverflowButtonClick(Sender: TObject);
    procedure FreezeButtonClick(Sender: TObject);
    procedure RefreshButtonClick(Sender: TObject);
    procedure ClearButtonClick(Sender: TObject);
    procedure FileListChange(Sender: TObject);
  private
    FWorker: TCrashDemoWorker;
    FResetting: Boolean;
    procedure AddActionBreadcrumb(const AAction: String);
    procedure CleanupFinishedWorker;
    procedure StopWorker;
    procedure UpdateStatus;
    procedure RefreshFiles;
    procedure ShowSelectedFile;
    procedure SetTriggerButtonsEnabled(const AValue: Boolean);
  end;

var
  CrashDemoMainForm: TCrashDemoMainForm;

implementation

uses
  System.IOUtils,
  Crash.Freeze,
  Crash.RawFallback,
  Crash.Reporter;

{$R *.fmx}

procedure TCrashDemoMainForm.FormCreate(Sender: TObject);
begin
  FWorker := nil;
  FResetting := False;
  ReportDirLabel.Text := 'Report directory: ' + CrashDemoReportDir;
  UpdateStatus;
  RefreshFiles;
end;

procedure TCrashDemoMainForm.FormDestroy(Sender: TObject);
begin
  HeartbeatTimer.Enabled := False;
  StopWorker;
end;

procedure TCrashDemoMainForm.AddActionBreadcrumb(const AAction: String);
begin
  TCrashReporter.AddBreadcrumb('ui', AAction);
end;

procedure TCrashDemoMainForm.CleanupFinishedWorker;
begin
  if (FWorker = nil) or (not FWorker.Finished) then
    Exit;
  FWorker.WaitFor;
  FreeAndNil(FWorker);
  WorkerButton.Enabled := not FResetting;
  RefreshFiles;
end;

procedure TCrashDemoMainForm.StopWorker;
begin
  if FWorker = nil then
    Exit;
  FWorker.Terminate;
  FWorker.WaitFor;
  FreeAndNil(FWorker);
end;

procedure TCrashDemoMainForm.SetTriggerButtonsEnabled(const AValue: Boolean);
begin
  RaiseButton.Enabled := AValue;
  AccessViolationButton.Enabled := AValue;
  WorkerButton.Enabled := AValue and (FWorker = nil);
  StackOverflowButton.Enabled := AValue;
  FreezeButton.Enabled := AValue;
end;

procedure TCrashDemoMainForm.UpdateStatus;
begin
  if FResetting then
    StatusMemo.Text := 'Reporter is restarting...'
  else
    StatusMemo.Text := CrashDemoStatusText;
end;

procedure TCrashDemoMainForm.RefreshFiles;
var
  Names: TStringList;
  FileName: String;
  Ext: String;
  Raw: TCrashRawRecord;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    if TDirectory.Exists(CrashDemoReportDir) then
      for FileName in TDirectory.GetFiles(CrashDemoReportDir) do
      begin
        Ext := LowerCase(TPath.GetExtension(FileName));
        if (Ext = '.el') or (Ext = '.pending') or
           ((Ext = '.crashraw') and CrashRawReadBlock(FileName, Raw)) then
          Names.Add(ExtractFileName(FileName));
      end;
    FileList.Items.Assign(Names);
  finally
    Names.Free;
  end;

  if FileList.Count > 0 then
    FileList.ItemIndex := 0
  else
    ReportMemo.Text := '(no crash artifacts)';
  ShowSelectedFile;
end;

procedure TCrashDemoMainForm.ShowSelectedFile;
var
  Path: String;
begin
  if FileList.ItemIndex < 0 then
    Exit;
  Path := TPath.Combine(CrashDemoReportDir,
    FileList.Items[FileList.ItemIndex]);
  try
    if SameText(TPath.GetExtension(Path), '.el') then
      ReportMemo.Text := TFile.ReadAllText(Path, TEncoding.Unicode)
    else
      ReportMemo.Text := Format('%s%sSize: %d bytes',
        [ExtractFileName(Path), sLineBreak, TFile.GetSize(Path)]);
  except
    on E: Exception do
      ReportMemo.Text := E.ClassName + ': ' + E.Message;
  end;
end;

procedure TCrashDemoMainForm.HeartbeatTimerTimer(Sender: TObject);
begin
  TCrashFreeze.Ping;
  CleanupFinishedWorker;
  UpdateStatus;
end;

procedure TCrashDemoMainForm.RaiseButtonClick(Sender: TObject);
begin
  AddActionBreadcrumb('software raise');
  CrashDemoTriggerSoftwareRaise;
end;

procedure TCrashDemoMainForm.AccessViolationButtonClick(Sender: TObject);
begin
  AddActionBreadcrumb('access violation');
  CrashDemoTriggerAccessViolation;
end;

procedure TCrashDemoMainForm.WorkerButtonClick(Sender: TObject);
begin
  if FWorker <> nil then
    Exit;
  AddActionBreadcrumb('registered worker access violation');
  FWorker := TCrashDemoWorker.Create;
  WorkerButton.Enabled := False;
  FWorker.Start;
end;

procedure TCrashDemoMainForm.StackOverflowButtonClick(Sender: TObject);
begin
  AddActionBreadcrumb('stack overflow');
  CrashDemoTriggerStackOverflow;
end;

procedure TCrashDemoMainForm.FreezeButtonClick(Sender: TObject);
begin
  AddActionBreadcrumb('freeze 15 seconds');
  CrashDemoTriggerFreeze;
  RefreshFiles;
end;

procedure TCrashDemoMainForm.RefreshButtonClick(Sender: TObject);
begin
  AddActionBreadcrumb('refresh artifacts');
  RefreshFiles;
end;

procedure TCrashDemoMainForm.ClearButtonClick(Sender: TObject);
begin
  if FResetting then
    Exit;
  FResetting := True;
  SetTriggerButtonsEnabled(False);
  RefreshButton.Enabled := False;
  ClearButton.Enabled := False;
  HeartbeatTimer.Enabled := False;
  UpdateStatus;
  try
    StopWorker;
    try
      CrashDemoResetArtifacts;
      ReportMemo.Text := '(artifacts cleared; reporter reinitialized)';
    except
      on E: Exception do
        ReportMemo.Text := E.ClassName + ': ' + E.Message;
    end;
  finally
    FResetting := False;
    HeartbeatTimer.Enabled := True;
    RefreshButton.Enabled := True;
    ClearButton.Enabled := True;
    SetTriggerButtonsEnabled(True);
    UpdateStatus;
    RefreshFiles;
  end;
end;

procedure TCrashDemoMainForm.FileListChange(Sender: TObject);
begin
  ShowSelectedFile;
end;

end.
