unit Crash.Dialog.FMX;

{ Modal FMX dialog for non-fatal exception reports (csOnException / csAcquired).

  Part of the Crash Reporter library - standalone, EurekaLog-compatible
  crash/exception reporting for Delphi cross-platform targets.

  Shows the .el-formatted report in a TMemo (read-only, scrollable). Two buttons:
    [OK]      = upload the report (if an URL is configured) and close.
    [Restart] = upload + restart the process. Hidden if CanRestart=False.

  This unit is optional and FMX-only. The host opts in by wiring it into the
  config:
    Cfg.OnShowDialog := ShowCrashDialog;
  and may optionally set CrashDialogTitle before the first crash. }

interface

var
  { Window caption. Host may override before the first report. }
  CrashDialogTitle: String = 'Error report';

{ Wire this into TCrashConfig.OnShowDialog. Blocks until the user closes it. }
procedure ShowCrashDialog(const AReportText: String);

implementation

uses
  System.Classes,
  System.SysUtils,
  System.UITypes,
  System.Types,
  System.Math,
  FMX.Forms,
  FMX.Memo,
  FMX.Memo.Types,
  FMX.ScrollBox,
  FMX.StdCtrls,
  FMX.Layouts,
  FMX.Types,
  FMX.Controls,
  FMX.Controls.Presentation,
  FMX.Dialogs,
  FMX.Graphics,
  FMX.Platform,
  Crash.Reporter;

type
  TCrashReportForm = class(TForm)
  private
    FMemo: TMemo;
    FBottomBar: TLayout;
    FOkButton: TButton;
    FRestartButton: TButton;
    FReportText: String; // pristine CRLF report for Upload - TMemo.Text re-joins lines with #10 on POSIX
    procedure DoOkClick(Sender: TObject);
    procedure DoRestartClick(Sender: TObject);
  protected
    procedure KeyDown(var Key: Word; var KeyChar: WideChar;
      Shift: TShiftState); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: NativeInt = 0); override;
    procedure SetReportText(const AText: String);
  end;

const
  BAR_H = 44;
  BTN_W = 110;
  BTN_H = 28;
  BTN_PAD = 8;
  FORM_W = 820;
  FORM_H = 560;

constructor TCrashReportForm.CreateNew(AOwner: TComponent; Dummy: NativeInt);
var
  RestartVisible: Boolean;
begin
  inherited;
  Caption := CrashDialogTitle;
  Width := FORM_W;
  Height := FORM_H;
  Position := TFormPosition.ScreenCenter;
  BorderStyle := TFmxFormBorderStyle.Sizeable;
  // FMX: build top-down - the bottom bar first (it "anchors" the bottom), the
  // memo fills the rest via Align.Client.
  FBottomBar := TLayout.Create(Self);
  FBottomBar.Parent := Self;
  FBottomBar.Align := TAlignLayout.Bottom;
  FBottomBar.Height := BAR_H;

  RestartVisible := TCrashReporter.CanRestart;

  // Reverse-stacking quirk of code-built FMX: for Right-align the last-created
  // child ends up leftmost. We want [OK | Restart] (OK on the left). So create
  // Restart first (it ends up rightmost), OK second (it lands left of Restart).
  if RestartVisible then
  begin
    FRestartButton := TButton.Create(Self);
    FRestartButton.Parent := FBottomBar;
    FRestartButton.Align := TAlignLayout.Right;
    FRestartButton.Width := BTN_W;
    FRestartButton.Margins.Right := BTN_PAD;
    FRestartButton.Margins.Top := (BAR_H - BTN_H) div 2;
    FRestartButton.Margins.Bottom := (BAR_H - BTN_H) div 2;
    FRestartButton.Text := 'Restart';
    FRestartButton.OnClick := DoRestartClick;
  end;

  FOkButton := TButton.Create(Self);
  FOkButton.Parent := FBottomBar;
  FOkButton.Align := TAlignLayout.Right;
  FOkButton.Width := BTN_W;
  FOkButton.Margins.Right := BTN_PAD;
  FOkButton.Margins.Top := (BAR_H - BTN_H) div 2;
  FOkButton.Margins.Bottom := (BAR_H - BTN_H) div 2;
  FOkButton.Text := 'OK';
  FOkButton.OnClick := DoOkClick;
  FOkButton.Default := True;
  FOkButton.ModalResult := mrOk;

  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.Align := TAlignLayout.Client;
  FMemo.ReadOnly := True;
  FMemo.WordWrap := False;
  FMemo.ShowScrollBars := True;
  FMemo.Margins.Left := 8;
  FMemo.Margins.Right := 8;
  FMemo.Margins.Top := 8;
  FMemo.Margins.Bottom := 4;
  // The EL format aligns the Call Stack columns with spaces for a monospace
  // font - on a proportional font the table falls apart. Drop Family/Size from
  // StyledSettings, otherwise the FMX style overrides them with defaults. Font
  // name is per-platform: 'Courier New' is not present on Linux/macOS.
  FMemo.StyledSettings := FMemo.StyledSettings - [TStyledSetting.Family, TStyledSetting.Size];
  {$IF Defined(MSWINDOWS)}
  FMemo.TextSettings.Font.Family := 'Consolas';
  {$ELSEIF Defined(MACOS) and not Defined(IOS)}
  FMemo.TextSettings.Font.Family := 'Menlo';
  {$ELSEIF Defined(LINUX)}
  FMemo.TextSettings.Font.Family := 'DejaVu Sans Mono';
  {$ELSE}
  FMemo.TextSettings.Font.Family := 'Courier New';
  {$ENDIF}
  FMemo.TextSettings.Font.Size := 10;
end;

function MeasureMaxLineWidth(const AText: String; const AFontFamily: String;
  const AFontSize: Single): Single;
// Measured in an off-screen TBitmap.Canvas - independent of whether the form is
// realized. Returns the width of the longest line in pixels.
var
  Bmp: TBitmap;
  Lines: TStringList;
  L: String;
  W: Single;
begin
  Result := 0;
  Bmp := TBitmap.Create(1, 1);
  try
    if not Bmp.Canvas.BeginScene then Exit;
    try
      Bmp.Canvas.Font.Family := AFontFamily;
      Bmp.Canvas.Font.Size   := AFontSize;
      Lines := TStringList.Create;
      try
        Lines.Text := AText;
        for L in Lines do
        begin
          W := Bmp.Canvas.TextWidth(L);
          if W > Result then Result := W;
        end;
      finally
        Lines.Free;
      end;
    finally
      Bmp.Canvas.EndScene;
    end;
  finally
    Bmp.Free;
  end;
end;

function GetScreenWidth: Single;
// Falls back to 1600 if the platform service is unavailable (Linux WSL headless, etc.)
var
  ScrSrv: IFMXScreenService;
begin
  Result := 1600;
  if TPlatformServices.Current.SupportsPlatformService(IFMXScreenService, ScrSrv) then
    Result := ScrSrv.GetScreenSize.X;
end;

procedure TCrashReportForm.SetReportText(const AText: String);
const
  H_PADDING = 50;  // memo Margins.Left+Right + vert.scrollbar + form chrome
var
  ContentW, MaxW, DesiredW: Single;
begin
  FReportText := AText;
  FMemo.Text := AText;
  FMemo.GoToTextBegin;

  ContentW := MeasureMaxLineWidth(AText, FMemo.TextSettings.Font.Family,
                                         FMemo.TextSettings.Font.Size);
  if ContentW > 0 then
  begin
    MaxW := GetScreenWidth * 0.9;
    DesiredW := ContentW + H_PADDING;
    // clamp: not narrower than the base FORM_W (UI must not shrink), not wider
    // than the screen.
    Width := Round(Min(MaxW, Max(FORM_W, DesiredW)));
    Position := TFormPosition.ScreenCenter; // re-center after resize
  end;
end;

procedure TCrashReportForm.DoOkClick(Sender: TObject);
begin
  // OK = send report + continue. Upload is synchronous - the user waits a few
  // seconds. On success drop the local .el (it's on the server now); on failure
  // keep it on disk for the next boot-recovery attempt.
  if TCrashReporter.Upload(FReportText, TCrashReporter.LastCrashFileName) then
    TCrashReporter.DeleteLastCrashFile;
  ModalResult := mrOk;
end;

procedure TCrashReportForm.DoRestartClick(Sender: TObject);
begin
  if TCrashReporter.Upload(FReportText, TCrashReporter.LastCrashFileName) then
    TCrashReporter.DeleteLastCrashFile;
  ModalResult := mrOk;
  TCrashReporter.Restart; // does not return (Halt in the child flow or after exec)
end;

procedure TCrashReportForm.KeyDown(var Key: Word; var KeyChar: WideChar;
  Shift: TShiftState);
begin
  // Esc = close without sending (same as the close box, ModalResult=mrCancel).
  if Key = vkEscape then
  begin
    Key := 0;
    ModalResult := mrCancel;
    Exit;
  end;
  inherited;
end;

procedure ShowCrashDialog(const AReportText: String);
var
  Frm: TCrashReportForm;
begin
  Frm := TCrashReportForm.CreateNew(nil);
  try
    Frm.SetReportText(AReportText);
    Frm.ShowModal;
  finally
    Frm.Free;
  end;
end;

end.
