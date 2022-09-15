program QoiTest;
{$IF CompilerVersion >= 21.0}
{$WEAKLINKRTTI ON}
{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$IFEND}
uses
  Forms,
  PngImage in 'PngImage.pas',
  QoiImage in '..\QoiImage.pas',
  Unit1 in 'Unit1.pas' {Form1};

{$R *.res}
begin
  Application.Initialize;
  //Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
