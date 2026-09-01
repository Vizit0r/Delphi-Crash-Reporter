program CrashDemoFMX;

uses
  System.StartUpCopy,
  FMX.Forms,
  Crash.MacOS.Api in '..\..\Crash.MacOS.Api.pas',
  Crash.Android.Symbols in '..\..\Crash.Android.Symbols.pas',
  Crash.Demangle in '..\..\Crash.Demangle.pas',
  Crash.LineNumbers in '..\..\Crash.LineNumbers.pas',
  Crash.MacOS.Symbols in '..\..\Crash.MacOS.Symbols.pas',
  Crash.MacOS.MachExc in '..\..\Crash.MacOS.MachExc.pas',
  Crash.Modules in '..\..\Crash.Modules.pas',
  Crash.Pending in '..\..\Crash.Pending.pas',
  Crash.Breadcrumbs in '..\..\Crash.Breadcrumbs.pas',
  Crash.RawFallback in '..\..\Crash.RawFallback.pas',
  Crash.Signals in '..\..\Crash.Signals.pas',
  Crash.ELFormat in '..\..\Crash.ELFormat.pas',
  Crash.CallStack in '..\..\Crash.CallStack.pas',
  Crash.Freeze in '..\..\Crash.Freeze.pas',
  Crash.Reporter in '..\..\Crash.Reporter.pas',
  CrashDemo.Runtime in 'CrashDemo.Runtime.pas',
  CrashDemo.MainForm in 'CrashDemo.MainForm.pas' {CrashDemoMainForm};

begin
  Application.Initialize;
  CrashDemoInitialize;
  Application.OnException := TCrashCapture.ExceptionHandler;
  Application.CreateForm(TCrashDemoMainForm, CrashDemoMainForm);
{$IFDEF ANDROID}
  { Android: Application.Run returns at once - the event loop lives in the native
    activity glue, so a finally here would disarm the reporter right after start. }
  Application.Run;
{$ELSE}
  try
    Application.Run;
  finally
    CrashDemoShutdown;
  end;
{$ENDIF}
end.
