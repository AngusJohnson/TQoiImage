unit QoiReader;

(*******************************************************************************
* Author    :  Angus Johnson                                                   *
* Version   :  0.99                                                            *
* Date      :  17 January 2022                                                 *
* Website   :  http://www.angusj.com                                           *
* Copyright :  Angus Johnson 2022                                              *
*                                                                              *
* Purpose   :  QOI image file decompiler                                       *
*                                                                              *
* License   :  Use, modification & distribution is subject to                  *
*              Boost Software License Ver 1                                    *
*              http://www.boost.org/LICENSE_1_0.txt                            *
*******************************************************************************)

interface

type
  PARGB = ^TARGB;
  TARGB = packed record
    case Boolean of
      false: (B,G,R,A: Byte);
      true: (Color: Cardinal);
  end;
  TArrayOfARGB = array of TARGB;

  TImage32Rec = record
    width   : integer;
    height  : integer;
    pixels  : TArrayOfARGB;
  end;

  TArrayOfByte = array of Byte;

function ReadQoi(bytes: TArrayOfByte): TImage32Rec;

implementation

const
  QOI_OP_INDEX    = $0;
  QOI_OP_DIFF     = $40;
  QOI_OP_LUMA     = $80;
  QOI_OP_RUN      = $C0;
  QOI_OP_RGB      = $FE;
  QOI_OP_RGBA     = $FF;
  QOI_MASK_2      = $C0;
  QOI_MAGIC       = $66696F71;
  QOI_HEADER_SIZE = 14;
  qoi_padding: array[0..7] of byte = (0,0,0,0,0,0,0,1);
  qoi_padding_size = 8;

type
  TQOI_DESC = packed record
    magic      : Cardinal;
    width      : Cardinal;
    height     : Cardinal;
    channels   : byte;
    colorspace : byte;
  end;
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------

function QOI_COLOR_HASH(c: TARGB): Byte;  {$IFDEF INLINE} inline; {$ENDIF}
begin
  Result := (c.R*3 + c.G*5 + c.B*7 + c.A*11) mod 64;
end;
//------------------------------------------------------------------------------

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
//------------------------------------------------------------------------------

function ReadByte(var p: PByte): Byte; {$IFDEF INLINE} inline; {$ENDIF}
begin
  Result := p^;
  inc(p);
end;
//------------------------------------------------------------------------------

function ReadQoi(bytes: TArrayOfByte): TImage32Rec;
var
  i, size, run, vg: integer;
  desc: TQOI_DESC;
  index: array[0..63] of TARGB;
  px: TARGB;
  b1, b2: byte;
  dst: PARGB;
  src: PByte;
begin
  Result.width := 0;
  Result.height := 0;
  Result.pixels := nil;

  size := Length(bytes);
  if size < QOI_HEADER_SIZE + qoi_padding_size then Exit;
  src := @bytes[0];

  Move(src^, desc, SizeOf(TQOI_DESC));
  inc(src, SizeOf(TQOI_DESC));
  with desc do
  begin
    width := SwapBytes(width);
    height := SwapBytes(height);
    if (magic <> QOI_MAGIC) or (width = 0) or (height = 0) or
      (channels < 3) or (channels > 4) or (colorspace > 1) then
        Exit;
    Result.width := width;
    Result.height := height;
    SetLength(Result.pixels, width * height);
  end;
  if Result.pixels = nil then Exit;

  dst := @Result.pixels[0];
  px.Color := $FF000000;
  run := 0;
  FillChar(index, SizeOf(index), 0);

  for i := 0 to Result.width * Result.height - 1 do
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
        vg := (b1 and $3f) - 32;
        px.R := px.R + vg - 8 + ((b2 shr 4) and $f);
        px.G := px.G + vg;
        px.B := px.B + vg - 8 + (b2 and $f);
      end
      else if (b1 and QOI_MASK_2) = QOI_OP_RUN then
        run := (b1 and $3f);
      index[QOI_COLOR_HASH(px)] := px;
    end;
    dst^ := px;
    inc(dst);
  end;
end;

end.
