program QoiTest;
{$IF CompilerVersion >= 21.0}
{$WEAKLINKRTTI ON}
{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$IFEND}
uses
  Forms,
  QoiImage in '..\QoiImage.pas',
  Unit1 in 'Unit1.pas' {Form1};

{$R *.res}
begin
  Application.Initialize;
{$IF COMPILERVERSION >= 18.5}
  Application.MainFormOnTaskbar := True;
{$IFEND}
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
