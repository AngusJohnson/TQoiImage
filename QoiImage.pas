unit QoiImage;

interface

(*******************************************************************************
* Author    :  Angus Johnson                                                   *
* Version   :  2.15                                                            *
* Date      :  15 September 2022                                               *
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
  SysUtils, Windows, Graphics, Math, Classes;

type
  TQOI_DESC = packed record
    magic: Cardinal;
    width: Cardinal;
    height: Cardinal;
    channels: Byte;
    colorspace: Byte;
  end;

{$IF COMPILERVERSION < 21}
  TBytes = array of Byte;
{$IFEND}

  TARGB = packed record
    case Boolean of
      false : (B: Byte; G: Byte; R: Byte; A: Byte);
      true  : (Color: Cardinal);
  end;
  PARGB = ^TARGB;
  TArrayOfARGB = array of TARGB;

  TQoiImageRec = record
    Width           : integer;
    Height          : integer;
    HasTransparency : Boolean;
    Pixels          : TArrayOfARGB; //top-down 4 bytes per pixel
  end;

  TQoiImage = class(TGraphic)
  private
    FQoi      : TQoiImageRec;
    procedure SetImageRec(const imgRec: TQoiImageRec);
  protected
    procedure Draw(ACanvas: TCanvas; const Rec: TRect); override;
    function  GetEmpty: Boolean; override;
    function  GetHeight: Integer; override;
    function  GetTransparent: Boolean; override;
    function  GetWidth: Integer; override;
    procedure SetHeight(Value: Integer); override;
    procedure SetWidth(Value: Integer); override;
  public
    procedure Assign(Source: TPersistent); override;
    procedure AssignTo(Dest: TPersistent); override;
    class function CanLoadFromStream(Stream: TStream): Boolean;
      {$IF COMPILERVERSION >= 33} override; {$IFEND} //Delphi 10.3 Rio
    procedure LoadFromStream(Stream: TStream); override;
    procedure SaveToFile(const Filename: string); override;
    procedure SaveToStream(Stream: TStream); override;
    procedure LoadFromClipboardFormat(AFormat: Word; AData: THandle;
      APalette: HPALETTE); override;
    procedure SaveToClipboardFormat(var AFormat: Word; var AData: THandle;
      var APalette: HPALETTE); override;
    procedure SetSize(AWidth, AHeight: Integer);
      {$IF COMPILERVERSION >= 23} override; {$IFEND} //?? check version
    property  ImageRec: TQoiImageRec read FQoi write SetImageRec;
  end;

  function  qoi_decode(const data: TBytes; out desc: TQOI_DESC): TArrayOfARGB;
  function  LoadFromQoiBytes(const bytes: TBytes): TQoiImageRec;
  function  LoadFromQoiStream(Stream: TStream): TQoiImageRec;

  function  qoi_encode(const data: Pointer; const desc: TQOI_DESC): TBytes;
  function  SaveToQoiBytes(const img: TQoiImageRec): TBytes;
  procedure SaveToQoiStream(const img: TQoiImageRec; Stream: TStream);

  function  GetImgRecFromBitmap(bmp: TBitmap): TQoiImageRec;
  function  CreateBitmapFromImgRec(const img: TQoiImageRec): TBitmap;

const QOI_MAGIC = $66696F71;

implementation

ResourceString
  sQoiImageFile = 'QOI image file';

const
  QOI_OP_INDEX = $0;
  QOI_OP_DIFF = $40;
  QOI_OP_LUMA = $80;
  QOI_OP_RUN = $C0;
  QOI_OP_RGB = $FE;
  QOI_OP_RGBA = $FF;
  QOI_MASK_2 = $C0;
  qoi_padding: array [0 .. 7] of Byte = (0, 0, 0, 0, 0, 0, 0, 1);

//------------------------------------------------------------------------------
// qoi_decode() and qoi_encode() and supporting functions
//------------------------------------------------------------------------------

function QOI_COLOR_HASH(c: TARGB): Byte;
  {$IF COMPILERVERSION >= 17} inline; {$IFEND}
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

function ReadByte(var p: PByte): Byte;
  {$IF COMPILERVERSION >= 17} inline; {$IFEND}
begin
  Result := p^;
  inc(p);
end;

procedure qoi_write_32(var p: PByte; val: Cardinal);
  {$IF COMPILERVERSION >= 17} inline; {$IFEND}
begin
  PCardinal(p)^ := val;
  inc(p, SizeOf(Cardinal));
end;

procedure qoi_write_8(var p: PByte; val: Byte);
  {$IF COMPILERVERSION >= 17} inline; {$IFEND}
begin
  p^ := val;
  inc(p);
end;

//qoi_decode: this function differs slightly from the standard at
//https://github.com/phoboslab/qoi/blob/master/qoi.h.
//The result here will instead always be an array of 4 byte pixels.
//Nevertheless the desc.channel field will reliably indicate image
//transparency such that 3 => alpha always 255; and 4 => alpha 0..255.

{$R-}
function qoi_decode(const data: TBytes; out desc: TQOI_DESC): TArrayOfARGB;
var
  run, vg, i: Integer;
  index: array [0 .. 63] of TARGB;
  px: TARGB;
  b1, b2: Byte;
  dst: PARGB;
  src: PByte;
  hasAlpha: Boolean;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (Length(data) < SizeOf(desc) + SizeOf(qoi_padding)) then Exit;

  src := @data[0];
  Move(src^, desc, SizeOf(desc));
  inc(src, SizeOf(desc));
  with desc do
  begin
    if (magic <> QOI_MAGIC) then Exit; //not valid QOI format
    width := SwapBytes(width);
    height := SwapBytes(height);
    SetLength(Result, width * height);
    if (width = 0) or (height = 0) or
      (channels < 3) or (channels > 4) or (colorspace > 1) then
        Exit;
  end;

  px.Color := $FF000000;
  run := 0;
  FillChar(index, SizeOf(index), 0);
  hasAlpha := false;
  desc.channels := 3;
  dst := @Result[0];
  for i := 0 to desc.width * desc.height -1 do
  begin
    if (run > 0) then
    begin
      Dec(run);
    end
    else
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
  if hasAlpha then desc.channels := 4;
end;
{$R+}

function qoi_encode(const data: Pointer; const desc: TQOI_DESC): TBytes;
var
  x,y,k,y2, max_size, run: Integer;
  vr, vg, vb, vg_r, vg_b: Integer;
  len, index_pos: Integer;
  dst: PByte;
  src: PARGB;
  index: array [0 .. 63] of TARGB;
  px_prev: TARGB;
begin
  Result := nil;
  len := desc.width * desc.height;

  max_size := len * 4 + SizeOf(desc) + SizeOf(qoi_padding);
  SetLength(Result, max_size);

  dst := @Result[0];
  qoi_write_32(dst, desc.magic);
  qoi_write_32(dst, SwapBytes(desc.Width));
  qoi_write_32(dst, SwapBytes(desc.Height));
  qoi_write_8(dst, desc.channels);
  qoi_write_8(dst, desc.colorspace);

  run := 0;
  px_prev.Color := $FF000000;
  FillChar(index, SizeOf(index), 0);

  src := data;
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
  max_size := Cardinal(dst) - Cardinal(@Result[0]);
  SetLength(Result, max_size);
end;

//------------------------------------------------------------------------------
// QOI Load and Save wrapper functions
//------------------------------------------------------------------------------

function LoadFromQoiBytes(const bytes: TBytes): TQoiImageRec;
var
  desc: TQOI_DESC;
begin
  Result.Pixels := qoi_decode(bytes, desc);
  Result.Width := desc.width;
  Result.Height := desc.height;
  Result.HasTransparency := desc.channels = 4;
end;

function LoadFromQoiStream(Stream: TStream): TQoiImageRec;
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

function SaveToQoiBytes(const img: TQoiImageRec): TBytes;
var
  desc: TQOI_DESC;
begin
  Result := nil;
  desc.magic := QOI_MAGIC;
  desc.width := img.Width;
  desc.height := img.Height;
  if img.HasTransparency then
    desc.channels := 4 else
    desc.channels := 3;
  desc.colorspace := 0;
  Result := qoi_encode(img.Pixels, desc);
end;

procedure SaveToQoiStream(const img: TQoiImageRec; Stream: TStream);
var
  bytes: TBytes;
begin
  bytes := SaveToQoiBytes(img);
  Stream.Write(bytes[0], Length(bytes));
end;

//------------------------------------------------------------------------------
//Exported GetImgRecFromBitmap & CreateBitmapFromImgRec amd support functions
//------------------------------------------------------------------------------

procedure SetAlpha255(var img: TQoiImageRec);
var
  i, len: integer;
  p: PARGB;
begin
  img.HasTransparency := false;
  len := Length(img.Pixels);
  if len = 0 then Exit;
  p := @img.Pixels[0];
  for i := 0 to len -1 do
  begin
    p.A := 255;
    inc(p);
  end;
end;

function GetHasTransparency(const img: TQoiImageRec): Boolean;
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
  Result := has0 = has255;
end;

function GetImgRecFromBitmap(bmp: TBitmap): TQoiImageRec;
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
    Result.HasTransparency := GetHasTransparency(Result);
  end else
  begin
    tmp := TBitmap.Create;
    try
      tmp.Assign(bmp);
      tmp.PixelFormat := pf32bit;
      GetBitmapBits(tmp.Handle, len *4, @Result.Pixels[0]);
      Result.HasTransparency := false;
    finally
      tmp.Free;
    end;
  end;
  if not Result.HasTransparency then SetAlpha255(Result);
end;

function CreateBitmapFromImgRec(const img: TQoiImageRec): TBitmap;
var
  i: integer;
  p: PARGB;
begin
  Result := TBitmap.Create;
  Result.Width := img.Width;
  Result.Height := img.Height;
  Result.PixelFormat := pf32bit;

  //for some reason SetBitmapBits fails with vey old Delphi compilers
  p := @img.Pixels[0];
  for i := 0 to img.Height -1 do
  begin
    Move(p^, Result.ScanLine[i]^, img.Width * 4);
    inc(p, img.Width);
  end;
  //SetBitmapBits(Result.Handle, img.Width * img.Height * 4, @img.Pixels[0]);
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
{$IF COMPILERVERSION >= 20}
      bmp.AlphaFormat := afDefined;
{$IFEND}
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

procedure TQoiImage.Draw(ACanvas: TCanvas; const Rec: TRect);
var
  bmp: TBitmap;
  BlendFunction: TBlendFunction;
  w, h: integer;
begin
  bmp := CreateBitmapFromImgRec(FQoi);
  try
    if Transparent then
    begin
{$IF COMPILERVERSION >= 20}
      bmp.AlphaFormat := afDefined;
{$IFEND}
      BlendFunction.BlendOp := AC_SRC_OVER;
      BlendFunction.AlphaFormat := AC_SRC_ALPHA;
      BlendFunction.SourceConstantAlpha := 255;
      BlendFunction.BlendFlags := 0;
      w := Math.Min(Width, Rec.Right - Rec.Left);
      h := Math.Min(Height, Rec.Bottom - Rec.Top);
      AlphaBlend(
        ACanvas.Handle, Rec.Left, Rec.Top, w, h,
        bmp.Canvas.Handle, 0, 0, w,h, BlendFunction);
    end else
      THackedBitmap(bmp).Draw(ACanvas, Rec);
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
  Result := FQoi.HasTransparency;
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
  FQoi.HasTransparency := false;
  SetLength(FQoi.Pixels, AWidth * AHeight);
  Changed(Self);
end;

procedure TQoiImage.SetImageRec(const imgRec: TQoiImageRec);
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
