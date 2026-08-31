unit Crash.Breadcrumbs;

{ Bounded, framework-agnostic breadcrumb storage for crash reports. }

interface

uses
  System.SysUtils,
  System.SyncObjs;

const
  CRASH_BREADCRUMB_DEFAULT_CAPACITY = 64;
  CRASH_BREADCRUMB_MAX_CAPACITY = 256;
  CRASH_BREADCRUMB_CATEGORY_CHARS = 48;
  CRASH_BREADCRUMB_MESSAGE_CHARS = 256;

type
  TCrashBreadcrumb = record
    Sequence: Int64;
    ElapsedMS: UInt64;
    ThreadID: UInt64;
    Category: String;
    MessageText: String;
  end;

  TCrashBreadcrumbStore = class
  private
    FLock: TCriticalSection;
    FItems: TArray<TCrashBreadcrumb>;
    FCapacity: Integer;
    FNext: Integer;
    FCount: Integer;
    FSequence: Int64;
    FStartTick: UInt64;
  public
    constructor Create(const ACapacity: Integer);
    destructor Destroy; override;
    procedure Add(const ACategory, AMessage: String);
    procedure Clear;
    function Snapshot: TArray<TCrashBreadcrumb>;
    function SnapshotText: String;
    property Capacity: Integer read FCapacity;
  end;

implementation

uses
  System.Classes,
  {$IF Defined(MSWINDOWS)}
  Winapi.Windows,
  {$ELSE}
  Posix.Pthread,
  {$ENDIF}
  System.Math;

const
  CRLF = #13#10;

function CrashBreadcrumbThreadID: UInt64;
begin
  {$IF Defined(MSWINDOWS)}
  Result := UInt64(GetCurrentThreadId);
  {$ELSE}
  Result := UInt64(NativeUInt(pthread_self));
  {$ENDIF}
end;

function CrashBreadcrumbSingleLine(const AText: String;
  const AMaxChars: Integer): String;
begin
  Result := StringReplace(AText, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  if Length(Result) > AMaxChars then
    SetLength(Result, AMaxChars);
end;

constructor TCrashBreadcrumbStore.Create(const ACapacity: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FCapacity := EnsureRange(ACapacity, 0, CRASH_BREADCRUMB_MAX_CAPACITY);
  SetLength(FItems, FCapacity);
  FStartTick := TThread.GetTickCount64;
end;

destructor TCrashBreadcrumbStore.Destroy;
begin
  FreeAndNil(FLock);
  inherited;
end;

procedure TCrashBreadcrumbStore.Add(const ACategory, AMessage: String);
var
  Item: TCrashBreadcrumb;
begin
  if FCapacity = 0 then
    Exit;
  Item := Default(TCrashBreadcrumb);
  Item.ElapsedMS := TThread.GetTickCount64 - FStartTick;
  Item.ThreadID := CrashBreadcrumbThreadID;
  Item.Category := CrashBreadcrumbSingleLine(ACategory,
    CRASH_BREADCRUMB_CATEGORY_CHARS);
  Item.MessageText := CrashBreadcrumbSingleLine(AMessage,
    CRASH_BREADCRUMB_MESSAGE_CHARS);
  FLock.Enter;
  try
    Inc(FSequence);
    Item.Sequence := FSequence;
    FItems[FNext] := Item;
    FNext := (FNext + 1) mod FCapacity;
    if FCount < FCapacity then
      Inc(FCount);
  finally
    FLock.Leave;
  end;
end;

procedure TCrashBreadcrumbStore.Clear;
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FItems) do
      FItems[I] := Default(TCrashBreadcrumb);
    FNext := 0;
    FCount := 0;
  finally
    FLock.Leave;
  end;
end;

function TCrashBreadcrumbStore.Snapshot: TArray<TCrashBreadcrumb>;
var
  First, I, SourceIndex: Integer;
begin
  Result := nil;
  if (FCapacity = 0) or (not FLock.TryEnter) then
    Exit;
  try
    SetLength(Result, FCount);
    First := FNext - FCount;
    if First < 0 then
      Inc(First, FCapacity);
    for I := 0 to FCount - 1 do
    begin
      SourceIndex := (First + I) mod FCapacity;
      Result[I] := FItems[SourceIndex];
    end;
  finally
    FLock.Leave;
  end;
end;

function TCrashBreadcrumbStore.SnapshotText: String;
var
  Items: TArray<TCrashBreadcrumb>;
  Item: TCrashBreadcrumb;
  SB: TStringBuilder;
begin
  Result := '';
  Items := Snapshot;
  if Length(Items) = 0 then
    Exit;
  SB := TStringBuilder.Create;
  try
    for Item in Items do
    begin
      if SB.Length > 0 then
        SB.Append(CRLF);
      SB.Append('#').Append(Item.Sequence);
      SB.Append(' +').Append(Item.ElapsedMS).Append('ms');
      SB.Append(' TID=').Append(Item.ThreadID);
      if Item.Category <> '' then
        SB.Append(' [').Append(Item.Category).Append(']');
      if Item.MessageText <> '' then
        SB.Append(' ').Append(Item.MessageText);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

end.
