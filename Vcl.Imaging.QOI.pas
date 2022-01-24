unit Vcl.Imaging.QOI;

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

(*******************************************************************************
* QOI - The "Quite OK Image" format for fast, lossless image compression       *
* Dominic Szablewski - https://phoboslab.org                                   *
* LICENSE : The MIT License(MIT)                                               *
*           Copyright(c) 2021 Dominic Szablewski                               *
*******************************************************************************)

uses
  System.SysUtils,
  Winapi.Windows,
  Vcl.Graphics,
  System.Math,
  System.Classes;

type

  TARGB = packed record
    case Boolean of
      false : (B: Byte; G: Byte; R: Byte; A: Byte);
      true  : (Color: Cardinal);
  end;
  PARGB = ^TARGB;
  TArrayOfARGB = array of TARGB;

  TImageRec = record
    Width     : Cardinal;
    Height    : Cardinal;
    //Channels (as per TQOI_DESC format below)
    //3: no alpha blending  (alpha: 255)
    //4: alpha blending     (alpha: 0-255)
    Channels  : Cardinal;
    //Pixels  : image layout is top-down
    Pixels    : TArrayOfARGB;
  end;

  TQoiImage = class(TGraphic)
  private
    FQoi      : TImageRec;
    procedure SetImageRec(const imgRec: TImageRec);
  protected
    procedure Draw(ACanvas: TCanvas; const Rect: TRect); override;
    function  GetEmpty: Boolean; override;
    function  GetHeight: Integer; override;
    function  GetTransparent: Boolean; override;
    function  GetWidth: Integer; override;
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
    property  HasTransparency: Boolean read GetTransparent;
    property  ImageRec: TImageRec read FQoi write SetImageRec;
  end;

  function  SaveToQoiBytes(const img: TImageRec): TBytes;
  function  LoadFromQoiBytes(const bytes: TBytes): TImageRec;

  procedure SaveToQoiStream(const img: TImageRec; Stream: TStream);
  function  LoadFromQoiStream(Stream: TStream): TImageRec;

  function  IsAlphaBlended(img: TImageRec): Boolean;

  function  GetImgRecFromBitmap(bmp: TBitmap): TImageRec;
  function  CreateBitmapFromImgRec(const img: TImageRec): TBitmap;

const QOI_MAGIC = $66696F71;

implementation

ResourceString
  sQoiImageFile = 'QOI image file';

type
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
  QOI_HEADER_SIZE = 14;
  qoi_padding: array [0 .. 7] of Byte = (0, 0, 0, 0, 0, 0, 0, 1);
  qoi_padding_size = 8;

function QOI_COLOR_HASH(c: TARGB): Byte; inline;
begin
  Result := (c.R * 3 + c.G * 5 + c.B * 7 + c.A * 11) and $3F;
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

function LoadFromQoiStream(Stream: TStream): TImageRec;
var
  len: integer;
  bytes: TBytes;
begin
  if not Assigned(Stream) then Exit;
  len := Stream.Size - Stream.Position;
  SetLength(bytes, len);
  Stream.Read(bytes[0], len);
  Result := LoadFromQoiBytes(bytes);
end;

{$R-}
function LoadFromQoiBytes(const bytes: TBytes): TImageRec;
var
  len, run, vg, i: Integer;
  desc: TQOI_DESC;
  index: array [0 .. 63] of TARGB;
  px: TARGB;
  b1, b2: Byte;
  dst: PARGB;
  src: PByte;
  hasAlpha: Boolean;
begin
  FillChar(Result, SizeOf(Result), 0);

  len := Length(bytes);
  if len < QOI_HEADER_SIZE + qoi_padding_size then Exit;

  src := @bytes[0];
  Move(src^, desc, SizeOf(TQOI_DESC));
  inc(src, SizeOf(TQOI_DESC));
  with desc do
  begin
    width := SwapBytes(width);
    height := SwapBytes(height);
    if (magic <> QOI_MAGIC) or (width = 0) or (height = 0) or (channels < 3) or
      (channels > 4) or (colorspace > 1) then
      Exit;
    Result.Width := width;
    Result.Height := height;
    SetLength(Result.Pixels, width * height);
  end;
  px.Color := $FF000000;
  run := 0;
  FillChar(index, SizeOf(index), 0);
  hasAlpha := false;

  dst := @Result.Pixels[0];
  for i := 0 to Result.Width * Result.Height -1 do
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
        hasAlpha := hasAlpha or (px.A < 255);
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

  if hasAlpha then
    Result.Channels := 4 else
    Result.Channels := 3;
end;
{$R+}

procedure SaveToQoiStream(const img: TImageRec; Stream: TStream);
var
  bytes: TBytes;
begin
  bytes := SaveToQoiBytes(img);
  Stream.Write(bytes[0], Length(bytes));
end;

function SaveToQoiBytes(const img: TImageRec): TBytes;
var
  x,y,k,y2, max_size, run, channels: Integer;
  vr, vg, vb, vg_r, vg_b: Integer;
  len, index_pos: Integer;
  dst: PByte;
  src: PARGB;
  index: array [0 .. 63] of TARGB;
  px_prev: TARGB;
begin
  Result := nil;
  len := img.Width * img.Height;
  if (len = 0) then Exit;

  channels := img.Channels;
  max_size := len * channels + QOI_HEADER_SIZE + qoi_padding_size;
  SetLength(Result, max_size);

  dst := @Result[0];
  qoi_write_32(dst, QOI_MAGIC);
  qoi_write_32(dst, SwapBytes(img.Width));
  qoi_write_32(dst, SwapBytes(img.Height));
  qoi_write_8(dst, channels);
  qoi_write_8(dst, 0); // colorspace

  run := 0;
  px_prev.Color := $FF000000;
  FillChar(index, SizeOf(index), 0);

  src := @img.Pixels[0];
  for y := 0 to len -1 do
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

  if (run > 0) then
    qoi_write_8(dst, QOI_OP_RUN or (run - 1));

  for x := 0 to 7 do
    qoi_write_8(dst, qoi_padding[x]);
  max_size := dst - PByte(@Result[0]);
  SetLength(Result, max_size);
end;

function CreateBitmapFromImgRec(const img: TImageRec): TBitmap;
begin
  Result := TBitmap.Create(img.Width, img.Height);
  Result.PixelFormat := pf32bit;
  SetBitmapBits(Result.Handle, img.Width * img.Height *4, @img.Pixels[0]);
end;

procedure SetAlpha255(var img: TImageRec);
var
  i, len: integer;
  p: PARGB;
begin
  len := Length(img.Pixels);
  if len = 0 then Exit;
  p := @img.Pixels[0];
  for i := 0 to len -1 do
  begin
    p.A := 255;
    inc(p);
  end;
end;

function IsAlphaBlended(img: TImageRec): Boolean;
var
  i, len: integer;
  p: PARGB;
  has0, has255: Boolean;
begin
  Result := true;
  len := Length(img.Pixels);
  if len = 0 then Exit;
  p := @img.Pixels[0];
  has0    := false;
  has255  := false;
  for i := 0 to len -1 do
  begin
    if p.A = 0 then has0 := true
    else if p.A = 255 then has255 := true
    else exit;
    inc(p);
  end;
  Result := has0 <> has255;
end;

function GetImgRecFromBitmap(bmp: TBitmap): TImageRec;
var
  len: integer;
  tmp: TBitmap;
begin
  FillChar(Result, SizeOf(Result), 0);
  len := bmp.Width * bmp.Height;
  SetLength(Result.Pixels, len);
  if len = 0 then Exit;
  Result.Width := bmp.Width;
  Result.Height := bmp.Height;

  if bmp.PixelFormat = pf32bit then
  begin
    GetBitmapBits(bmp.Handle, len *4, @Result.Pixels[0]);
    if IsAlphaBlended(Result) then
      Result.Channels := 4 else
      Result.Channels := 3;
  end else
  begin
    tmp := TBitmap.Create;
    try
      tmp.Assign(bmp);
      tmp.PixelFormat := pf32bit;
      GetBitmapBits(tmp.Handle, len *4, @Result.Pixels[0]);
      Result.Channels := 3;
    finally
      tmp.Free;
    end;
  end;
  if Result.Channels = 3 then SetAlpha255(Result);
end;

//------------------------------------------------------------------------------
// TQoiImage methods
//------------------------------------------------------------------------------

procedure TQoiImage.AssignTo(Dest: TPersistent);
var
  bmp: TBitmap;
begin
  if Dest is TQoiImage then
    TQoiImage(Dest).Assign(self)
  else if Dest is TBitmap then
  begin
    bmp := CreateBitmapFromImgRec(FQoi);
    try
      TBitmap(Dest).Assign(bmp);
    finally
      bmp.Free;
    end;
  end
  else inherited;
end;

procedure TQoiImage.Assign(Source: TPersistent);
begin
  if (Source is TQoiImage) then
  begin
    FQoi := TQoiImage(Source).FQoi;
    Changed(self);
  end
  else if Source is TBitmap then
  begin
    FQoi := GetImgRecFromBitmap(TBitmap(Source));
    Changed(self);
  end
  else inherited;
end;

type THackedBitmap = class(TBitmap);

procedure TQoiImage.Draw(ACanvas: TCanvas; const Rect: TRect);
var
  bmp: TBitmap;
  BlendFunction: TBlendFunction;
  w, h: integer;
begin
  bmp := CreateBitmapFromImgRec(FQoi);
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

function TQoiImage.GetEmpty: Boolean;
begin
  Result := FQoi.Width * FQoi.Height = 0;
end;

function TQoiImage.GetTransparent: Boolean;
begin
  if FQoi.Channels = 4 then Result := true
  else if FQoi.Channels = 3 then Result := false
  else
  begin
    Result := IsAlphaBlended(FQoi);
    if Result then FQoi.Channels := 4
    else FQoi.Channels := 3;
  end;
end;

function TQoiImage.GetHeight: Integer;
begin
  Result := FQoi.Height;
end;

function TQoiImage.GetWidth: Integer;
begin
  Result := FQoi.Width;
end;

procedure TQoiImage.SetHeight(Value: Integer);
begin
  SetSize(Width, Value);
end;

procedure TQoiImage.SetWidth(Value: Integer);
begin
  SetSize(Value, Height);
end;

procedure TQoiImage.SetSize(AWidth, AHeight: Integer);
begin
  FQoi.Width := AWidth;
  FQoi.Height := AHeight;
  FQoi.Channels := 0;
  SetLength(FQoi.Pixels, AWidth * AHeight);
  Changed(Self);
end;

procedure TQoiImage.SetImageRec(const imgRec: TImageRec);
begin
  FQoi := imgRec;
  Changed(Self);
end;

class function TQoiImage.CanLoadFromStream(Stream: TStream): Boolean;
var
  p: Int64;
  q: Cardinal;
begin
  p := Stream.Position;
  try
    Result := (Stream.Read(q, 4) = 4) and (q = QOI_MAGIC);
  finally
    Stream.Position := p;
  end;
end;

procedure TQoiImage.LoadFromStream(Stream: TStream);
begin
  if not Assigned(Stream) then Exit;
  FQoi := LoadFromQoiStream(Stream);
  Changed(Self);
end;

procedure TQoiImage.SaveToFile(const Filename: string);
begin
  inherited;
end;

procedure TQoiImage.SaveToStream(Stream: TStream);
begin
  SaveToQoiStream(FQoi, Stream);
end;

procedure TQoiImage.LoadFromClipboardFormat(AFormat: Word; AData: THandle;
  APalette: HPALETTE);
var
  bmp: TBitmap;
begin
  bmp := TBitmap.Create;
  try
    THackedBitmap(bmp).LoadFromClipboardFormat(AFormat, AData, APalette);
    FQoi := GetImgRecFromBitmap(bmp);
  finally
    bmp.Free;
  end;
end;

procedure TQoiImage.SaveToClipboardFormat(var AFormat: Word;
  var AData: THandle; var APalette: HPALETTE);
var
  bmp: TBitmap;
begin
  bmp := CreateBitmapFromImgRec(FQoi);
  try
    THackedBitmap(bmp).SaveToClipboardFormat(AFormat, AData, APalette);
  finally
    bmp.Free;
  end;
end;

initialization
  TPicture.RegisterFileFormat('QOI', sQoiImageFile, TQoiImage); // Do not localize

end.
