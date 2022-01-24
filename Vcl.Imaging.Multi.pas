unit Vcl.Imaging.Multi;

interface

(*******************************************************************************
* Author    :  Angus Johnson                                                   *
* Version   :  2.12                                                             *
* Date      :  24 January 2022                                                 *
* Website   :  http://www.angusj.com                                           *
* License   :  The MIT License (MIT)                                           *
*              Copyright (c) 2021-2022 Angus Johnson                           *
*              https://opensource.org/licenses/MIT                             *
*******************************************************************************)

uses
  System.SysUtils,
  Winapi.Windows,
  Vcl.Graphics,
  Vcl.Imaging.Qoi,
  Vcl.Imaging.pngimage,
  Vcl.Imaging.jpeg,
  Vcl.ExtCtrls,
  System.Math,
  System.Classes;

type
  TStreamFormat = (sfUnknown, sfQoi, sfBmp, sfPng, sfJpg);

  TRGB = packed record
    B: Byte; G: Byte; R: Byte;
  end;
  PRGB = ^TRGB;

  TMultiImage = class(TGraphic)
  private
    fImg        : TImageRec;
    fSaveFmt    : TStreamFormat;
    function GetPixels: TArrayOfARGB;
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function GetEmpty: Boolean; override;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetWidth(Value: Integer); override;
  public
    procedure Assign(Source: TPersistent); override;
    procedure AssignTo(Dest: TPersistent); override;
    class function CanLoadFromStream(Stream: TStream): Boolean; override;
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToFile(const Filename: string); override;
    procedure SaveToStream(Stream: TStream); override;
    procedure LoadFromClipboardFormat(AFormat: Word; AData: THandle;
      APalette: HPALETTE); override;
    procedure SaveToClipboardFormat(var AFormat: Word; var AData: THandle;
      var APalette: HPALETTE); override;
    procedure SetSize(AWidth, AHeight: Integer); override;
    property HasTransparency: Boolean read GetTransparent;
    //nb: when altering the pixels directly, call Changed afterwards.
    property Pixels: TArrayOfARGB read GetPixels; //image layout is top-down
  end;

  function GetStreamFormat(stream: TStream): TStreamFormat;
  function CreatePngImageFromImgRec(const img: TImageRec): TPNGImage;
  function CreateJpegImageFromImgRec(const img: TImageRec): TJPEGImage;

  function GetImgRecFromPngImage(png: TPngImage): TImageRec;
  function GetImgRecFromJpegImage(jpeg: TJPEGImage): TImageRec;

implementation

type
  THackedBitmap = class(TBitmap);
  TArrayOfByte = array of Byte;

function GetStreamFormat(stream: TStream): TStreamFormat;
var
  p: Int64;
  q: Cardinal;
const
  bmpFlag = $4D42;
  jpgFlag = $FFD8FF;
  pngFlag = $474E5089;
begin
  p := Stream.Position;
  try
    if Stream.Read(q, 4) <> 4 then Result := sfUnknown
    else if (q = QOI_MAGIC) then Result := sfQoi
    else if (q = pngFlag) then Result := sfPng
    else if ((q and $FFFF) = bmpFlag) then Result := sfBmp
    else if ((q and $FFFFFF) = jpgFlag) then Result := sfJpg
    else Result := sfUnknown;
  finally
    Stream.Position := p;
  end;
end;

function CreatePngImageFromImgRec(const img: TImageRec): TPNGImage;
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

function GetImgRecFromPngImage(png: TPngImage): TImageRec;
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
    Result.Channels := 4;
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

function CreateJpegImageFromImgRec(const img: TImageRec): TJPEGImage;
var
  bmp: TBitmap;
begin
  Result := TJPEGImage.Create;
  bmp := CreateBitmapFromImgRec(img);
  try
    Result.Assign(bmp);
  finally
    bmp.Free;
  end;
end;

type THackedJpeg = class(TJPEGImage);

function GetImgRecFromJpegImage(jpeg: TJPEGImage): TImageRec;
begin
  Result := GetImgRecFromBitmap(THackedJpeg(jpeg).Bitmap);
end;

//------------------------------------------------------------------------------
// TMultiImage methods
//------------------------------------------------------------------------------

procedure TMultiImage.AssignTo(Dest: TPersistent);
var
  png: TPngImage;
  bmp: TBitmap;
begin
  if Dest is TMultiImage then
    TMultiImage(Dest).Assign(self)
  else if Dest is TQoiImage then
    TQoiImage(Dest).ImageRec := fImg
  else if Dest is TBitmap then
  begin
    bmp := CreateBitmapFromImgRec(fImg);
    try
      if HasTransparency then
        bmp.AlphaFormat := afDefined;
      TBitmap(Dest).Assign(bmp);
    finally
      bmp.Free;
    end;
  end else if Dest is TPngImage then
  begin
    png := CreatePngImageFromImgRec(fImg);
    try
      TPngImage(Dest).Assign(png);
    finally
      png.Free;
    end;
  end
  else if Dest is TJpegImage then
  begin
    bmp := CreateBitmapFromImgRec(fImg);
    try
      TJpegImage(Dest).Assign(bmp);
    finally
      bmp.Free;
    end;
  end
  else inherited;
end;

procedure TMultiImage.Assign(Source: TPersistent);
begin
  if (Source is TMultiImage) then
    with TMultiImage(Source).fImg do
  begin
    fImg.Width := Width;
    fImg.Height := Height;
    fImg.Pixels := Copy(Pixels, 0, Length(Pixels));
    Changed(Self);
  end
  else if (Source is TPngImage) then
  begin
    fImg := GetImgRecFromPngImage(TPngImage(Source));
    Changed(Self);
  end
  else if (Source is TJPEGImage) then
  begin
    fImg := GetImgRecFromJpegImage(TJPEGImage(Source));
    Changed(Self);
  end
  else if (Source is TBitmap) then
  begin
    fImg := GetImgRecFromBitmap(TBitmap(Source));
    Changed(Self);
  end;
end;

procedure TMultiImage.Draw(ACanvas: TCanvas; const Rect: TRect);
var
  bmp: TBitmap;
  BlendFunction: TBlendFunction;
  w, h: integer;
begin
  bmp := CreateBitmapFromImgRec(fImg);
  try
    if HasTransparency then
    begin
      bmp.AlphaFormat := afDefined;
      BlendFunction.BlendOp := AC_SRC_OVER;
      BlendFunction.AlphaFormat := AC_SRC_ALPHA;
      BlendFunction.SourceConstantAlpha := 255;
      BlendFunction.BlendFlags := 0;
      w := System.Math.Min(Width, Rect.Width);
      h := System.Math.Min(Height, Rect.Height);
      Winapi.Windows.AlphaBlend(
        ACanvas.Handle, Rect.Left, Rect.Top, w, h,
        bmp.Canvas.Handle, 0, 0, w,h, BlendFunction);
    end else
      THackedBitmap(bmp).Draw(ACanvas, Rect);
  finally
    bmp.Free;
  end;
end;

function TMultiImage.GetEmpty: Boolean;
begin
  Result := fImg.Width * fImg.Height = 0;
end;

function TMultiImage.GetTransparent: Boolean;
begin
  Result := IsAlphaBlended(fImg);
end;

function TMultiImage.GetPixels: TArrayOfARGB;
begin
  Result := fImg.Pixels;
end;

function TMultiImage.GetHeight: Integer;
begin
  Result := fImg.Height;
end;

function TMultiImage.GetWidth: Integer;
begin
  Result := fImg.Width;
end;

procedure TMultiImage.SetHeight(Value: Integer);
begin
  SetSize(Width, Value);
end;

procedure TMultiImage.SetWidth(Value: Integer);
begin
  SetSize(Value, Height);
end;

procedure TMultiImage.SetSize(AWidth, AHeight: Integer);
begin
  fImg.Width := AWidth;
  fImg.Height := AHeight;
  SetLength(fImg.Pixels, AWidth * AHeight);
  Changed(Self);
end;

class function TMultiImage.CanLoadFromStream(Stream: TStream): Boolean;
begin
  Result := GetStreamFormat(stream) <> sfUnknown;
end;

procedure TMultiImage.LoadFromStream(Stream: TStream);
var
  bmp: TBitmap;
  png: TPngImage;
  jpg: TJPEGImage;
  sf: TStreamFormat;
begin
  if not Assigned(Stream) then Exit;
  sf := GetStreamFormat(Stream);
  case sf of
    sfQoi:
      begin
        fImg := LoadFromQoiStream(Stream);
        Changed(Self);
      end;
    sfBmp:
      begin
        bmp := TBitmap.Create;
        try
          bmp.LoadFromStream(Stream);
          Assign(bmp);
        finally
          bmp.Free;
        end;
      end;
    sfPng:
      begin
        png := TPngImage.Create;
        try
          png.LoadFromStream(Stream);
          Assign(png);
        finally
          png.Free;
        end;
      end;
    sfJpg:
      begin
        jpg := TJPEGImage.Create;
        try
          jpg.LoadFromStream(Stream);
          Assign(jpg);
        finally
          jpg.Free;
        end;
      end;
  end;
end;

procedure TMultiImage.SaveToFile(const Filename: string);
var
  ext: string;
begin
  ext := Lowercase(ExtractFileExt(Filename));
  if ext = '.bmp' then fSaveFmt := sfBmp
  else if ext = '.png' then fSaveFmt := sfPng
  else if ext = '.jpg' then fSaveFmt := sfJpg
  else if ext = '.jpeg' then fSaveFmt := sfJpg
  else fSaveFmt := sfQoi;
  inherited;
  fSaveFmt := sfUnknown;
end;

procedure TMultiImage.SaveToStream(Stream: TStream);
var
  bmp: TBitmap;
  png: TPngImage;
  jpg: TJPEGImage;
begin
  case fSaveFmt of
    sfBmp:
      begin
        bmp := CreateBitmapFromImgRec(fImg);
        try
          bmp.SaveToStream(Stream);
        finally
          bmp.Free;
        end;
      end;
    sfPng:
      begin
        png := CreatePngImageFromImgRec(fImg);
        try
          png.SaveToStream(Stream);
        finally
          png.Free;
        end;
      end;
    sfJpg:
      begin
        jpg := CreateJpegImageFromImgRec(fImg);
        try
          jpg.SaveToStream(Stream);
        finally
          jpg.Free;
        end;
      end;
    else
      SaveToQoiStream(fImg, Stream);
  end;
end;

procedure TMultiImage.LoadFromClipboardFormat(AFormat: Word; AData: THandle;
  APalette: HPALETTE);
var
  bmp: TBitmap;
begin
  bmp := TBitmap.Create;
  try
    THackedBitmap(bmp).LoadFromClipboardFormat(AFormat, AData, APalette);
    Assign(bmp);
  finally
    bmp.Free;
  end;
end;

procedure TMultiImage.SaveToClipboardFormat(var AFormat: Word;
  var AData: THandle; var APalette: HPALETTE);
var
  bmp: TBitmap;
begin
  bmp := CreateBitmapFromImgRec(fImg);
  try
    THackedBitmap(bmp).SaveToClipboardFormat(AFormat, AData, APalette);
  finally
    bmp.Free;
  end;
end;

end.
