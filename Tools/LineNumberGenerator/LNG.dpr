program LNG;

{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}
{$R *.res}

uses
  System.SysUtils,
  Dwarf in 'Source\Dwarf.pas',
  Generator in 'Source\Generator.pas',
  GolEncoder in 'Source\GolEncoder.pas',
  MachO in 'Source\MachO.pas',
  Crash.LineNumbers in '..\..\Crash.LineNumbers.pas',
  Crash.MacOS.Api in '..\..\Crash.MacOS.Api.pas';

procedure Run;
var
  Generator: TLineNumberGenerator;
begin
  if (ParamCount <> 1) then
  begin
    WriteLn('Usage: LineNumberGenerator <path to MacOS64 executable>');
    Halt(1);
  end;

  Generator := TLineNumberGenerator.Create(ParamStr(1));
  try
    Generator.Run;
  finally
    Generator.Free;
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
