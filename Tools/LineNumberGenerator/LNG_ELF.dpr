program LNG_ELF;
{ Linux ELF / DWARF -> .gol generator. Counterpart to LNG.dpr (which handles
  macOS Mach-O + .dSYM). See README.md. }

{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}
{$R *.res}

uses
  System.SysUtils,
  Dwarf in 'Source\Dwarf.pas',
  Elf in 'Source\Elf.pas',
  GeneratorElf in 'Source\GeneratorElf.pas',
  GolEncoder in 'Source\GolEncoder.pas',
  GosymWriter in 'Source\GosymWriter.pas',
  Crash.LineNumbers in '..\..\Crash.LineNumbers.pas',
  Crash.SymbolFile in '..\..\Crash.SymbolFile.pas';

procedure Run;
var
  Generator: TElfLineNumberGenerator;
  WriteSymbols: Boolean;
begin
  WriteSymbols := (ParamCount = 2) and SameText(ParamStr(1), '--gosym');
  if (ParamCount <> 1) and not WriteSymbols then
  begin
    WriteLn('Usage: LNG_ELF [--gosym] <path to ELF64 image>');
    WriteLn('  --gosym  also write <path>.gosym (local function names) from .symtab');
    Halt(1);
  end;

  Generator := TElfLineNumberGenerator.Create(ParamStr(ParamCount), WriteSymbols);
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
