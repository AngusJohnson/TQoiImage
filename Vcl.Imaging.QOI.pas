unit Vcl.Imaging.QOI;

interface

(*******************************************************************************
* Author    :  Angus Johnson                                                   *
* Version   :  1.0                                                          *
* Date      :  29 December 2021                                                *
* Website   :  http://www.angusj.com                                           *
* Copyright :  Angus Johnson 2021                                              *
*                                                                              *
* License   :  The MIT License(MIT), see below.                                *
*******************************************************************************)

(*******************************************************************************
QOI - The "Quite OK Image" format for fast, lossless image compression
Dominic Szablewski - https://phoboslab.org
LICENSE: The MIT License(MIT)
Copyright(c) 2021 Dominic Szablewski
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files(the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and / or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions :
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*******************************************************************************)

uses
  System.SysUtils,
  Winapi.Windows,
  Vcl.Graphics,
  Vcl.ExtCtrls,
  System.Math,
  System.Classes;

type
  TTriState = (tsUnknown, tsFalse, tsTrue);
  TQoiImage = class(TGraphic)
  private
    FBitmap     : TBitmap;
    FSaveAsBmp  : Boolean;
    FHasTransPx : TTriState;
    function  GetHasTrans: Boolean;
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function GetEmpty: Boolean; override;
    function GetHeight: Integer; override;
    function GetTransparent: Boolean; override;
    function GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetWidth(Value: Integer); override;
    property Image: TBitmap read FBitmap;
  public
    constructor Create; override;
    destructor Destroy; override;
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
    property HasTransparency: Boolean read GetHasTrans;
  end;

implementation

uses Vcl.Imaging.pngimage;

ResourceString
  sQoiImageFile = 'QOI image file';

type
  THackedBitmap = class(TBitmap);

  TColor32 = type Cardinal;

  TARGB = packed record
    case Boolean of
      false:
        (B: Byte; G: Byte; R: Byte; A: Byte);
      true:
        (Color: TColor32);
  end;

  PARGB = ^TARGB;
  TArrayOfColor32 = array of TColor32;
  TArrayOfByte = array of Byte;

  TQOI_DESC = packed record
    magic: Cardinal;
    width: Cardinal;
    height: Cardinal;
    channels: Byte;
    colorspace: Byte;
  end;

const
  QOI_OP_INDEX = $0;
  QOI_OP_DIFF = $40;
  QOI_OP_LUMA = $80;
  QOI_OP_RUN = $C0;
  QOI_OP_RGB = $FE;
  QOI_OP_RGBA = $FF;
  QOI_MASK_2 = $C0;
  QOI_MAGIC = $66696F71;
  QOI_HEADER_SIZE = 14;
  qoi_padding: array [0 .. 7] of Byte = (0, 0, 0, 0, 0, 0, 0, 1);
  qoi_padding_size = 8;

function QOI_COLOR_HASH(c: TARGB): Byte; inline;
begin
  Result := (c.R * 3 + c.G * 5 + c.B * 7 + c.A * 11) mod 64;
end;

function SwapBytes(Value: Cardinal): Cardinal;
var
  v: array[0..3] of byte absolute Value;
  r: array[0..3] of byte absolute Result;
begin
  r[3] := v[0];
  r[2] := v[1];
  r[1] := v[2];
  r[0] := v[3];
end;

function ReadByte(var p: PByte): Byte; inline;
begin
  Result := p^;
  inc(p);
end;

procedure qoi_write_32(var p: PByte; val: Cardinal); inline;
begin
  PCardinal(p)^ := val;
  inc(p, SizeOf(Cardinal));
end;

procedure qoi_write_8(var p: PByte; val: Byte); inline;
begin
  p^ := val;
  inc(p);
end;

function Bmp32HasTransparency(bmp: TBitmap): Boolean;
var
  i : Integer;
  c : PARGB;
begin
  Result := bmp.PixelFormat = pf32bit;
  if not Result then Exit;
  c := PARGB(bmp.ScanLine[bmp.Height -1]);
  for i := 0 to bmp.Width * bmp.Height -1 do
  begin
    if c.A < 255 then Exit;
    inc(c);
  end;
  Result := false;
end;

function CreateTransparentPNG(qoi: TQoiImage): TPNGImage;
var
  X, Y: integer;
  src: PARGB;
  dstAlpha: PByte;
begin
  Result := TPNGImage.CreateBlank(COLOR_RGBALPHA,
    8, qoi.Width , qoi.Height);

  Result.CreateAlpha;
  Result.Canvas.CopyMode:= cmSrcCopy;
  Result.Canvas.Draw(0, 0, qoi);

  for Y := 0 to Pred(qoi.Height) do
  begin
    src := qoi.Image.ScanLine[Y];
    dstAlpha := PByte(Result.AlphaScanline[Y]);
    for X := 0 to Pred(qoi.width) do
    begin
      dstAlpha^ :=  src.A;
      Inc(dstAlpha);
      Inc(src);
    end;
  end;
end;

//------------------------------------------------------------------------------
// TQoiImage methods
//------------------------------------------------------------------------------

constructor TQoiImage.Create;
begin
  inherited;
  FBitmap := TBitmap.Create;
end;

destructor TQoiImage.Destroy;
begin
  FBitmap.Free;
  inherited;
end;

procedure TQoiImage.AssignTo(Dest: TPersistent);
var
  tmpPng: TPngImage;
begin
  if Dest is TQoiImage then
  begin
    TQoiImage(Dest).Image.Assign(Image);
    TQoiImage(Dest).FHasTransPx := FHasTransPx;
  end else if Dest is TBitmap then
  begin
    TBitmap(Dest).SetSize(Width, Height);
    TBitmap(Dest).PixelFormat := pf32bit;
    TBitmap(Dest).Canvas.Draw(0,0, self);
  end
  else if Dest is TPngImage then
  begin
    tmpPng := CreateTransparentPNG(self);
    try
      TPngImage(Dest).Assign(tmpPng);
    finally
      tmpPng.Free;
    end;
  end
  else inherited;
end;

procedure TQoiImage.Assign(Source: TPersistent);
begin
  if Source is TQoiImage then
  begin
    Image.Assign(TQoiImage(Source).Image);
    FHasTransPx := TQoiImage(Source).FHasTransPx;
  end
  else if Source is TBitmap then
  begin
    Image.Assign(Source);
    FHasTransPx := tsUnknown;
  end else
  begin
    Image.Assign(Source);
    FHasTransPx := tsUnknown;
  end;
end;

function TQoiImage.GetHasTrans: Boolean;
begin
  case FHasTransPx of
    tsUnknown:
      begin
        Result := Bmp32HasTransparency(Image);
        if Result then
          FHasTransPx := tsTrue else
          FHasTransPx := tsFalse;
      end;
    tsFalse: Result := false;
    else Result := true;
  end;
end;

procedure TQoiImage.Draw(ACanvas: TCanvas; const Rect: TRect);
var
  BlendFunction: TBlendFunction;
  w, h: integer;
  bmp: TBitmap;
begin
  if HasTransparency then
  begin
    //Premultiplication is a prerequisite for Windows' alpha
    //blending but it will marginally degrade the original image.
    //Hence we'll premultiply a temporary copy of the image.
    bmp := TBitmap.create;
    try
      bmp.Assign(Image);
      bmp.AlphaFormat := afPremultiplied;
      BlendFunction.BlendOp := AC_SRC_OVER;
      BlendFunction.AlphaFormat := AC_SRC_ALPHA;
      BlendFunction.SourceConstantAlpha := 255;
      BlendFunction.BlendFlags := 0;
      w := System.Math.Min(Width, Rect.Width);
      h := System.Math.Min(Height, Rect.Height);
      Winapi.Windows.AlphaBlend(
        ACanvas.Handle, Rect.Left, Rect.Top, w, h,
        bmp.Canvas.Handle, 0, 0, w,h, BlendFunction);
    finally
      bmp.Free;
    end;
  end else
    THackedBitmap(Image).Draw(ACanvas, Rect);
end;

function TQoiImage.GetEmpty: Boolean;
begin
  Result := THackedBitmap(Image).GetEmpty;
end;

function TQoiImage.GetHeight: Integer;
begin
  Result := THackedBitmap(Image).GetHeight;
end;

function TQoiImage.GetTransparent: Boolean;
begin
  Result := THackedBitmap(Image).GetTransparent;
end;

function TQoiImage.GetWidth: Integer;
begin
  Result := THackedBitmap(Image).GetWidth;
end;

procedure TQoiImage.SetHeight(Value: Integer);
begin
  THackedBitmap(Image).SetHeight(Value);
end;

procedure TQoiImage.SetWidth(Value: Integer);
begin
  THackedBitmap(Image).SetWidth(Value);
end;

class function TQoiImage.CanLoadFromStream(Stream: TStream): Boolean;
var
  p: Int64;
  QOI_DESC: TQOI_DESC;
begin
  p := Stream.Position;
  try
    Result := (Stream.Read(QOI_DESC, SizeOf(TQOI_DESC)) = SizeOf(TQOI_DESC)) and
      (QOI_DESC.magic = QOI_MAGIC) and (QOI_DESC.width > 0) and
      (QOI_DESC.height > 0);
  finally
    Stream.Position := p;
  end;

  if not Result then
    Result := TBitmap.CanLoadFromStream(Stream);
end;

{$R-}
procedure TQoiImage.LoadFromStream(Stream: TStream);
var
  size, run, vg, x, y: Integer;
  desc: TQOI_DESC;
  index: array [0 .. 63] of TARGB;
  px: TARGB;
  b1, b2: Byte;
  dst: PARGB;
  src: PByte;
  srcTmp: TArrayOfByte;
begin
  if not Assigned(Stream) then
    Exit;

  if TBitmap.CanLoadFromStream(Stream) then
  begin
    Image.LoadFromStream(Stream);
    Exit;
  end;

  size := Stream.size - Stream.Position;
  if size < QOI_HEADER_SIZE + qoi_padding_size then
    Exit;

  if Stream is TMemoryStream then
  begin
    src := TMemoryStream(Stream).Memory;
    inc(src, Stream.Position);
  end
  else
  begin
    SetLength(srcTmp, size);
    Stream.Read(srcTmp[0], size);
    src := @srcTmp[0];
  end;

  Move(src^, desc, SizeOf(TQOI_DESC));
  inc(src, SizeOf(TQOI_DESC));
  with desc do
  begin
    width := SwapBytes(width);
    height := SwapBytes(height);
    if (magic <> QOI_MAGIC) or (width = 0) or (height = 0) or (channels < 3) or
      (channels > 4) or (colorspace > 1) then
      Exit;
    Image.PixelFormat := pf32bit;
    Image.SetSize(width, height);
  end;
  px.Color := $FF000000;
  run := 0;
  FillChar(index, SizeOf(index), 0);
  FHasTransPx := tsUnknown;

  for y := 0 to Image.height -1 do
  begin
    dst := PARGB(Image.ScanLine[y]);
    for x := 0 to Image.Width -1 do
    begin
      if (run > 0) then
      begin
        Dec(run);
      end else
      begin
        b1 := ReadByte(src);
        if (b1 = QOI_OP_RGB) then
        begin
          px.R := ReadByte(src);
          px.G := ReadByte(src);
          px.B := ReadByte(src);
        end
        else if (b1 = QOI_OP_RGBA) then
        begin
          px.R := ReadByte(src);
          px.G := ReadByte(src);
          px.B := ReadByte(src);
          px.A := ReadByte(src);
        end
        else if ((b1 and QOI_MASK_2) = QOI_OP_INDEX) then
        begin
          px := index[b1];
        end
        else if (b1 and QOI_MASK_2) = QOI_OP_DIFF then
        begin
          px.R := px.R + ((b1 shr 4) and 3) - 2;
          px.G := px.G + ((b1 shr 2) and 3) - 2;
          px.B := px.B + (b1 and 3) - 2;
        end
        else if (b1 and QOI_MASK_2) = QOI_OP_LUMA then
        begin
          b2 := ReadByte(src);
          vg := (b1 and $3F) - 32;
          px.R := px.R + vg - 8 + ((b2 shr 4) and $F);
          px.G := px.G + vg;
          px.B := px.B + vg - 8 + (b2 and $F);
        end
        else if (b1 and QOI_MASK_2) = QOI_OP_RUN then
          run := (b1 and $3F);
        index[QOI_COLOR_HASH(px)] := px;
      end;
      dst.Color := px.Color;
      inc(dst);
    end;
  end;
  Changed(Self);
end;
{$R+}

procedure TQoiImage.SaveToFile(const Filename: string);
begin
  FSaveAsBmp := SameText('.bmp', ExtractFileExt(Filename));
  inherited;
  FSaveAsBmp := false;
end;

procedure TQoiImage.SaveToStream(Stream: TStream);
var
  x,y,k,y2, max_size, run: Integer;
  vr, vg, vb, vg_r, vg_b: Integer;
  index_pos: Integer;
  bytes: TArrayOfByte;
  dst: PByte;
  src: PARGB;
  index: array [0 .. 63] of TARGB;
  px_prev: TARGB;
begin
  if not Assigned(Stream) or Image.Empty then
    Exit;

  if FSaveAsBmp then
  begin
    Image.SaveToStream(Stream);
    Exit;
  end;

  max_size := Image.width * Image.height * SizeOf(TColor32) + QOI_HEADER_SIZE +
    qoi_padding_size;
  SetLength(bytes, max_size);
  Image.PixelFormat := pf32bit;

  dst := @bytes[0];
  qoi_write_32(dst, QOI_MAGIC);
  qoi_write_32(dst, SwapBytes(Image.width));
  qoi_write_32(dst, SwapBytes(Image.height));
  qoi_write_8(dst, 4); // channels
  qoi_write_8(dst, 0); // colorspace

  run := 0;
  px_prev.Color := $FF000000;
  FillChar(index, SizeOf(index), 0);

  //Images appear to be always stored bottom-up in memory
  //(even those saved to file as top-down) and this makes
  //pixel-parsing slightly more difficult).
  for y := 0 to Image.height -1 do
  begin
    src := PARGB(Image.ScanLine[y]);
    for x := 1 to Width do
    begin
      if src.Color = px_prev.Color then
      begin
        inc(run);
        if (run = 62) then
        begin
          qoi_write_8(dst, QOI_OP_RUN or (run - 1));
          run := 0;
        end;
      end
      else
      begin
        if (run > 0) then
        begin
          qoi_write_8(dst, QOI_OP_RUN or (run - 1));
          run := 0;
        end;

        index_pos := QOI_COLOR_HASH(src^);
        if (index[index_pos].Color = src.Color) then
        begin
          qoi_write_8(dst, QOI_OP_INDEX or index_pos);
        end
        else
        begin
          index[index_pos] := src^;
          if (src.A = px_prev.A) then
          begin
            vr := src.R - px_prev.R;
            vg := src.G - px_prev.G;
            vb := src.B - px_prev.B;
            vg_r := vr - vg;
            vg_b := vb - vg;
            if ((vr > -3) and (vr < 2) and (vg > -3) and (vg < 2) and (vb > -3)
              and (vb < 2)) then
            begin
              qoi_write_8(dst, QOI_OP_DIFF or (vr + 2) shl 4 or (vg + 2) shl 2 or
                (vb + 2));
            end
            else if ((vg_r > -9) and (vg_r < 8) and (vg > -33) and (vg < 32) and
              (vg_b > -9) and (vg_b < 8)) then
            begin
              qoi_write_8(dst, QOI_OP_LUMA or (vg + 32));
              qoi_write_8(dst, (vg_r + 8) shl 4 or (vg_b + 8));
            end
            else
            begin
              qoi_write_8(dst, QOI_OP_RGB);
              qoi_write_8(dst, src.R);
              qoi_write_8(dst, src.G);
              qoi_write_8(dst, src.B);
            end
          end
          else
          begin
            qoi_write_8(dst, QOI_OP_RGBA);
            qoi_write_8(dst, src.R);
            qoi_write_8(dst, src.G);
            qoi_write_8(dst, src.B);
            qoi_write_8(dst, src.A);
          end;
        end;
      end;
      px_prev := src^;
      inc(src);
    end;
  end;

  if (run > 0) then
    qoi_write_8(dst, QOI_OP_RUN or (run - 1));

  for x := 0 to 7 do
    qoi_write_8(dst, qoi_padding[x]); // colorspace
  max_size := dst - PByte(@bytes[0]);
  Stream.Write(bytes[0], max_size);
end;

procedure TQoiImage.LoadFromClipboardFormat(AFormat: Word; AData: THandle;
  APalette: HPALETTE);
begin
  THackedBitmap(Image).LoadFromClipboardFormat(AFormat, AData, APalette);
end;

procedure TQoiImage.SaveToClipboardFormat(var AFormat: Word; var AData: THandle;
  var APalette: HPALETTE);
begin
  THackedBitmap(Image).SaveToClipboardFormat(AFormat, AData, APalette);
end;

procedure TQoiImage.SetSize(AWidth, AHeight: Integer);
begin
  THackedBitmap(Image).SetSize(AWidth, AHeight);
end;

initialization

TPicture.RegisterFileFormat('QOI', sQoiImageFile, TQoiImage); // Do not localize

finalization

TPicture.UnregisterGraphicClass(TQoiImage);

end.
