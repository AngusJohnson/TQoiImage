unit Unit1;

interface

uses
  Windows, SysUtils, ShlObj, ShellApi, Classes, Graphics,
  ComCtrls, Menus, Controls, Forms, StdCtrls, ExtCtrls, Dialogs,
  Diagnostics, QoiImage, PngImage, Jpeg;

type
  TForm1 = class(TForm)
    Panel1: TPanel;
    btnPNG: TButton;
    StatusBar1: TStatusBar;
    btnConvertFolder: TButton;
    MainMenu1: TMainMenu;
    File1: TMenuItem;
    mnuExit: TMenuItem;
    Open1: TMenuItem;
    N1: TMenuItem;
    OpenDialog1: TOpenDialog;
    image: TImage;
    btnQoi: TButton;
    FileOpenDialog: TFileOpenDialog;
    procedure btnPNGClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure btnConvertFolderClick(Sender: TObject);
    procedure mnuExitClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure Open1Click(Sender: TObject);
    procedure btnQoiClick(Sender: TObject);
  public
    foldername: string;
    procedure LoadImage(const filename: string);
    procedure TimeTest(testPng: Boolean);
  end;

var
  Form1: TForm1;

const
  pngFile = './tmp.png';
  qoiFile = './tmp.qoi';

implementation

{$R *.dfm}

type
  THackedJpeg     = class(TJPEGImage);

  TRGB = packed record
    B: Byte; G: Byte; R: Byte;
  end;
  PRGB = ^TRGB;

function GetFileSize(const filename: string): Int64;
var
  info: TWin32FileAttributeData;
begin
  if GetFileAttributesEx(PChar(filename),
    GetFileExInfoStandard, @info) then
    result := Int64(info.nFileSizeLow) or
      Int64(info.nFileSizeHigh shl 32) else
    result := -1;
end;

function GetQoiImgRecFromPngImage(png: TPngImage): TQoiImageRec;
var
  X,Y     : Cardinal;
  dst     : PARGB;
  src     : PRGB;
  srcAlpha: PByte;
  bmp     : TBitmap;
begin
  Result.Width := png.Width;
  Result.Height := png.Height;
  SetLength(Result.Pixels, png.Width * png.Height);
  if png.TransparencyMode = ptmPartial then //alpha blended transparency
  begin
    Result.HasTransparency := true;
    dst := @Result.Pixels[0];
    for Y := 0 to png.Height -1 do
    begin
      src := png.Scanline[Y];
      srcAlpha := PByte(png.AlphaScanline[Y]);
      for X := 0 to png.width -1 do
      begin
        dst.B := src.B; dst.G := src.G; dst.R := src.R;
        dst.A := srcAlpha^;
        inc(dst); Inc(srcAlpha); inc(src);
      end;
    end;
  end else
  begin
    bmp := TBitmap.Create;
    try
      png.AssignTo(bmp);
      Result := GetImgRecFromBitmap(bmp);
    finally
      bmp.Free;
    end;
  end;
end;

function CreatePngImageFromImgRec(const img: TQoiImageRec): TPNGImage;
var
  X,Y: Cardinal;
  src: PARGB;
  dst: PRGB;
  dstAlpha: PByte;
begin
  Result := TPNGImage.CreateBlank(COLOR_RGBALPHA, 8, img.Width , img.Height);
  Result.CreateAlpha;
  if img.Width * img.Height = 0 then Exit;

  src := @img.Pixels[0];
  for Y := 0 to img.Height -1 do
  begin
    dst := Result.Scanline[Y];
    dstAlpha := PByte(Result.AlphaScanline[Y]);
    for X := 0 to img.width -1 do
    begin
      dst.B := src.B; dst.G := src.G; dst.R := src.R;
      dstAlpha^ :=  src.A;
      Inc(dstAlpha); inc(dst); inc(src);
    end;
  end;
end;

function GetQoiImgRecFromJpegImage(jpeg: TJPEGImage): TQoiImageRec;
begin
  Result := GetImgRecFromBitmap(THackedJpeg(jpeg).Bitmap);
  Result.HasTransparency := false;
end;

//------------------------------------------------------------------------------
// TForm1 methods
//------------------------------------------------------------------------------

procedure TForm1.FormCreate(Sender: TObject);
begin
  StatusBar1.Font.Style := [fsBold];
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if FileExists(qoiFile) then DeleteFile(qoiFile);
  if FileExists(pngFile) then DeleteFile(pngFile);
end;

procedure TForm1.LoadImage(const filename: string);
var
  ext: string;
  png : TPngImage;
  jpg : TJpegImage;
  qoi : TQoiImage;
begin
  StatusBar1.SimpleText := '  Wait ...';
  btnPNG.Enabled := false;
  btnQoi.Enabled := false;
  image.Picture := nil;
  ext := Lowercase(ExtractFileExt(filename));
  Application.ProcessMessages;

  if ext = '.png' then
  begin
    png := TPngImage.Create;
    png.LoadFromFile(filename);
    image.Picture.Bitmap.Assign(png);
    CopyFile(PChar(filename), PChar(pngFile), false);
    qoi := TQoiImage.Create;
    qoi.ImageRec := GetQoiImgRecFromPngImage(png);
    qoi.SaveToFile(qoiFile);
    qoi.Free;
    png.Free;
  end
  else if ext = '.jpg' then
  begin
    jpg := TJpegImage.Create;
    jpg.LoadFromFile(filename);
    image.Picture.Bitmap.Assign(jpg);
    qoi := TQoiImage.Create;
    qoi.ImageRec := GetQoiImgRecFromJpegImage(jpg);
    qoi.SaveToFile(qoiFile);
    png := CreatePngImageFromImgRec(qoi.ImageRec);
    png.SaveToFile(pngFile);
    qoi.Free;
    png.Free;
    jpg.Free;
  end
  else if ext = '.qoi' then
  begin
    qoi := TQoiImage.Create;
    qoi.LoadFromFile(filename);
    image.Picture.Bitmap.Assign(qoi);
    CopyFile(PChar(filename), PChar(qoiFile), false);
    png := CreatePngImageFromImgRec(qoi.ImageRec);
    png.SaveToFile(pngFile);
    qoi.Free;
    png.Free;
  end else
    Exit;

  StatusBar1.SimpleText := '';
  btnPNG.Enabled := true;
  btnQoi.Enabled := true;
  if Active then
    btnPNG.SetFocus;
end;

procedure TForm1.TimeTest(testPng: Boolean);
var
  fileSize, T1, T2: Int64;
  ext, filename: string;
  png: TPngImage;
  qoi: TQoiImage;
begin
  if testPng then filename := pngFile
  else filename := qoiFile;

  fileSize := GetFileSize(filename);
  if fileSize <= 0 then
  begin
    StatusBar1.SimpleText := '  Invalid image.';
    Exit;
  end;

  btnPng.Enabled := False;
  btnQoi.Enabled := False;
  image.Picture := nil;
  StatusBar1.SimpleText := '  Wait ...';
  Application.ProcessMessages;
  try
    if testPng then
    begin
      Ext := 'PNG';
      png := TPngImage.Create;
      { decode }
      with TStopWatch.StartNew do
      begin
        png.LoadFromFile(filename);
        T1 := ElapsedMilliseconds;
      end;
      { encode }
      with TStopWatch.StartNew do
      begin
        png.SaveToFile(filename);
        T2 := ElapsedMilliseconds;
      end;
      //and display the image
      image.Picture.Bitmap.Assign(png);
      png.Free;
    end else
    begin
      Ext := 'QOI';
      qoi := TQoiImage.Create;
      { decode }
      with TStopWatch.StartNew do
      begin
        qoi.LoadFromFile(filename);
        T1 := ElapsedMilliseconds;
      end;
      { encode }
      with TStopWatch.StartNew do
      begin
        qoi.SaveToFile(filename);
        T2 := ElapsedMilliseconds;
      end;
      //and display the image
      image.Picture.Bitmap.Assign(qoi);
      qoi.Free;
    end;

  finally
    btnPng.Enabled := true;
    btnQoi.Enabled := true;
  end;

  StatusBar1.SimpleText :=
    Format('  %s - File Size: %1.0n; Encode: %1d ms; Decode: %1d ms.',
      [Ext, FileSize/1.0, T2, T1]);
end;

procedure TForm1.btnPNGClick(Sender: TObject);
begin
  TimeTest(true);
end;

procedure TForm1.btnQoiClick(Sender: TObject);
begin
  TimeTest(false);
end;

procedure TForm1.btnConvertFolderClick(Sender: TObject);
var
  i,j,cnt: integer;
  n, n2: string;
  sr: TSearchRec;
  png: TPngImage;
  qoi: TQoiImage;
begin
  if not FileOpenDialog.Execute then Exit;
  foldername := FileOpenDialog.FileName + '\';
  StatusBar1.SimpleText := '';

  cnt := 0;
  i := FindFirst(foldername +'*.png', faAnyFile, sr);
  while i = 0 do
  begin
    if sr.Name[1] <> '.' then inc(cnt);
    i := FindNext(sr);
  end;
  FindClose(sr);
  if cnt = 0 then Exit;

  StatusBar1.SimpleText := '  Wait ...';
  Application.ProcessMessages;
  ForceDirectories(foldername + 'QOI\');

  png := TPngImage.Create;
  qoi := TQoiImage.Create;
  try
    j := 0;
    i := FindFirst(foldername +'*.png', faAnyFile, sr);
    while i = 0 do
    begin
      if j mod 5 = 0 then
      begin
        StatusBar1.SimpleText :=  format('  %d/%d files processed',[j, cnt]);
        Application.ProcessMessages;
      end;
      inc(j);
      if sr.Name[1] <> '.' then
      begin
        n := foldername + sr.Name;
        png.LoadFromFile(n);
        qoi.ImageRec := GetQoiImgRecFromPngImage(png);
        n2 := foldername + 'QOI\' + ChangeFileExt(sr.Name, '.qoi');
        qoi.SaveToFile(n2);
      end;
      i := FindNext(sr);
    end;
    FindClose(sr);

  finally
    qoi.Free;
    png.Free;
    StatusBar1.SimpleText := '  All done';
  end;
end;

procedure TForm1.mnuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TForm1.Open1Click(Sender: TObject);
begin
  if OpenDialog1.Execute then
    LoadImage(OpenDialog1.FileName);
  StatusBar1.SimpleText := '';
end;

end.
