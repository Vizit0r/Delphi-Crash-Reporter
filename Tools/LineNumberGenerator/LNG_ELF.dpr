program LNG_ELF;
{ Linux ELF / DWARF -> .gol generator. Counterpart to LNG.dpr (which handles
  macOS Mach-O + .dSYM). See README_stealth.md. }

{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}
{$R *.res}

uses
  System.SysUtils,
  Dwarf in 'Source\Dwarf.pas',
  Elf in 'Source\Elf.pas',
  GeneratorElf in 'Source\GeneratorElf.pas',
  Crash.LineNumbers in '..\..\Crash.LineNumbers.pas';

procedure Run;
var
  Generator: TElfLineNumberGenerator;
begin
  if (ParamCount <> 1) then
  begin
    WriteLn('Usage: LNG_ELF <path to Linux64 ELF executable>');
    Halt(1);
  end;

  Generator := TElfLineNumberGenerator.Create(ParamStr(1));
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
