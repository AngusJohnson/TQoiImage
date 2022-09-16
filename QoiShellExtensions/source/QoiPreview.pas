unit QoiPreview;

(*******************************************************************************
* Author    :  Angus Johnson                                                   *
* Version   :  1.2                                                            *
* Date      :  30 January 2022                                                 *
* Website   :  http://www.angusj.com                                           *
* Copyright :  Angus Johnson 2022                                              *
*                                                                              *
* Purpose   :  IPreviewHandler and IThumbnailProvider for QOI image files      *
*                                                                              *
* License   :  Use, modification & distribution is subject to                  *
*              Boost Software License Ver 1                                    *
*              http://www.boost.org/LICENSE_1_0.txt                            *
*******************************************************************************)

interface

uses
  Windows, Messages, ActiveX, Classes, ComObj, ComServ, ShlObj,
  PropSys, Types, Registry, SysUtils, Math, QoiReader;

{$WARN SYMBOL_PLATFORM OFF}

{$R dialog.res}

const
  extension = '.qoi';
  extFile = 'qoiFile';
  extDescription = 'QOI Shell Extensions';

  SID_EXT_ShellExtensions = '{0C2DCD0D-2A02-4D2B-9EAC-F8737DEAA7DF}';
  IID_EXT_ShellExtensions: TGUID = SID_EXT_ShellExtensions;

  SID_IThumbnailProvider = '{E357FCCD-A995-4576-B01F-234630154E96}';
  IID_IThumbnailProvider: TGUID = SID_IThumbnailProvider;

  darkBkColor = $202020;
  ID_IMAGE = 101; //dialog static control ID

type
  TWTS_ALPHATYPE = (WTSAT_UNKNOWN, WTSAT_RGB, WTSAT_ARGB);
  PHBITMAP = ^HBITMAP;

  IThumbnailProvider = interface(IUnknown)
    [SID_IThumbnailProvider]
    function GetThumbnail(cx: Cardinal; out hbmp: HBITMAP;
      out at: TWTS_ALPHATYPE): HRESULT; stdcall;
  end;

  TQoiShelExt = class(TComObject,
    IPreviewHandler, IThumbnailProvider, IInitializeWithStream)
  strict private
    function IInitializeWithStream.Initialize = IInitializeWithStream_Init;
    //IPreviewHandler
    function DoPreview: HRESULT; stdcall;
    function QueryFocus(var phwnd: HWND): HRESULT; stdcall;
    function SetFocus: HRESULT; stdcall;
    function SetRect(var prc: TRect): HRESULT; stdcall;
    function SetWindow(hwnd: HWND; var prc: TRect): HRESULT; stdcall;
    function TranslateAccelerator(var pmsg: tagMSG): HRESULT; stdcall;
    function Unload: HRESULT; stdcall;
    //IThumbnailProvider
    function GetThumbnail(cx: Cardinal; out hbmp: HBITMAP; out at: TWTS_ALPHATYPE): HRESULT; stdcall;
    //IInitializeWithStream
    function IInitializeWithStream_Init(const pstream: IStream;
      grfMode: DWORD): HRESULT; stdcall;
  private
    FBounds   : TRect;
    fParent   : HWND;
    fDialog   : HWND;
    fSrcImg   : TImage32Rec;
    fStream   : IStream;
    fDarkBrush: HBrush;
    fDarkModeChecked: Boolean;
    fDarkModeEnabled: Boolean;
    procedure CleanupObjects;
    procedure CheckDarkMode;
    procedure RedrawDialog;
  public
    destructor Destroy; override;
  end;

implementation

function GetStreamSize(stream: IStream): Cardinal;
var
  statStg: TStatStg;
begin
  if stream.Stat(statStg, STATFLAG_NONAME) = S_OK then
    Result := statStg.cbSize else
    Result := 0;
end;

function SetStreamPos(stream: IStream; pos: Int64): Int64;
var
  res: LargeUInt;
begin
  stream.Seek(pos, STREAM_SEEK_SET, res);
  Result := res;
end;

procedure FixAlpha(var img: TImage32Rec);
var
  i: integer;
begin
  //if the alpha channel is all 0's then reset to 255
  for i := 0 to High(img.pixels) do
    if img.pixels[i].A > 0 then Exit;
  for i := 0 to High(img.pixels) do
    img.pixels[i].A := 255;
end;
//------------------------------------------------------------------------------

function Make32BitBitmapFromPxls(const img: TImage32Rec): HBitmap;
var
  len : integer;
  dst : PARGB;
  bi  : TBitmapV4Header;
begin
  Result := 0;
  len := Length(img.pixels);
  if len <> img.width * img.height then Exit;
  FillChar(bi, sizeof(bi), #0);
  bi.bV4Size := sizeof(TBitmapV4Header);
  bi.bV4Width := img.width;
  bi.bV4Height := -img.height;
  bi.bV4Planes := 1;
  bi.bV4BitCount := 32;
  bi.bV4SizeImage := len *4;
  bi.bV4V4Compression := BI_RGB;
  bi.bV4RedMask       := $FF shl 16;
  bi.bV4GreenMask     := $FF shl 8;
  bi.bV4BlueMask      := $FF;
  bi.bV4AlphaMask     := Cardinal($FF) shl 24;

  Result := CreateDIBSection(0,
    PBitmapInfo(@bi)^, DIB_RGB_COLORS, Pointer(dst), 0, 0);
  Move(img.pixels[0], dst^, len * 4);
end;
//------------------------------------------------------------------------------

function ClampByte(val: double): byte; inline;
begin
  if val <= 0 then result := 0
  else if val >= 255 then result := 255
  else result := Round(val);
end;
//------------------------------------------------------------------------------

type
  TWeightedColor = record
  private
    fAddCount : Integer;
    fAlphaTot : Int64;
    fColorTotR: Int64;
    fColorTotG: Int64;
    fColorTotB: Int64;
    function GetColor: TARGB;
  public
    procedure Reset; inline;
    procedure Add(c: TARGB; w: Integer = 1); overload;
    procedure Add(const other: TWeightedColor); overload; inline;
    procedure AddWeight(w: Integer); inline;
    property AddCount: Integer read fAddCount;
    property Color: TARGB read GetColor;
    property Weight: integer read fAddCount;
  end;
  TArrayOfWeightedColor = array of TWeightedColor;

//------------------------------------------------------------------------------
//------------------------------------------------------------------------------

function BilinearResample(const img: TImage32Rec; x256, y256: Integer): TARGB;
var
  xi,yi, weight: Integer;
  iw, ih: integer;
  color: TWeightedColor;
  xf, yf: cardinal;
begin
  iw := img.Width;
  ih := img.Height;

  if (x256 <= -$100) or (x256 >= iw *$100) or
     (y256 <= -$100) or (y256 >= ih *$100) then
  begin
    result.Color := 0;
    Exit;
  end;

  if x256 < 0 then xi := -1
  else xi := x256 shr 8;

  if y256 < 0 then yi := -1
  else yi := y256 shr 8;

  xf := x256 and $FF;
  yf := y256 and $FF;

  color.Reset;

  weight := (($100 - xf) * ($100 - yf)) shr 8;        //top-left
  if (xi < 0) or (yi < 0) then
    color.AddWeight(weight) else
    color.Add(img.Pixels[xi + yi * iw], weight);

  weight := (xf * ($100 - yf)) shr 8;                 //top-right
  if ((xi+1) >= iw) or (yi < 0) then
    color.AddWeight(weight) else
    color.Add(img.Pixels[(xi+1) + yi * iw], weight);

  weight := (($100 - xf) * yf) shr 8;                 //bottom-left
  if (xi < 0) or ((yi+1) >= ih) then
    color.AddWeight(weight) else
    color.Add(img.Pixels[xi + (yi+1) * iw], weight);

  weight := (xf * yf) shr 8;                          //bottom-right
  if (xi + 1 >= iw) or (yi + 1 >= ih) then
    color.AddWeight(weight) else
    color.Add(img.Pixels[(xi+1) + (yi+1) * iw], weight);

  Result := color.Color;
end;
//------------------------------------------------------------------------------

function ImageResize(const img: TImage32Rec;
  newWidth, newHeight: integer): TImage32Rec;
var
  i,j: integer;
  invX,invY: double;
  pc: PARGB;
begin
  Result.width := newWidth;
  Result.height := newHeight;
  SetLength(Result.pixels, newWidth * newHeight);
  invX := 256 *img.width/newWidth;
  invY := 256 *img.height/newHeight;

  pc := @Result.pixels[0];
  for i := 0 to + newHeight -1 do
    for j := 0 to newWidth -1 do
    begin
      pc^ := BilinearResample(img,
        Round(j * invX), Round(i * invY));
      inc(pc);
    end;
end;

//------------------------------------------------------------------------------
// TQoiPreviewHandler
//------------------------------------------------------------------------------

destructor TQoiShelExt.Destroy;
begin
  CleanupObjects;
  fStream := nil;
  inherited Destroy;
end;
//------------------------------------------------------------------------------

procedure TQoiShelExt.CheckDarkMode;
var
  reg: TRegistry;
begin
  fDarkModeChecked := true;
  reg := TRegistry.Create(KEY_READ); //specific access rights important here
  try
    reg.RootKey := HKEY_CURRENT_USER;
    fDarkModeEnabled := reg.OpenKey(
      'SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize', false) and
      reg.ValueExists('SystemUsesLightTheme') and
      (reg.ReadInteger('SystemUsesLightTheme') = 0);
  finally
    reg.Free;
  end;
end;
//------------------------------------------------------------------------------

procedure TQoiShelExt.CleanupObjects;
var
  imgCtrl: HWnd;
begin
  fSrcImg.pixels := nil;
  if fDialog <> 0 then
  begin
    imgCtrl := GetDlgItem(fDialog, ID_IMAGE);
    //https://devblogs.microsoft.com/oldnewthing/20140219-00/?p=1713
    DeleteObject(SendMessage(imgCtrl, STM_SETIMAGE, IMAGE_BITMAP, 0));
    DestroyWindow(fDialog);
    fDialog := 0;
    if fDarkBrush <> 0 then DeleteObject(fDarkBrush);
    fDarkBrush := 0;
  end;
end;
//------------------------------------------------------------------------------

procedure TQoiShelExt.RedrawDialog;
var
  l,t,w,h : integer;
  scale   : double;
  imgCtrl : HWnd;
  img     : TImage32Rec;
  bm,oldBm: HBitmap;
begin
  if fDialog = 0 then Exit;
  w := RectWidth(FBounds);
  h := RectHeight(FBounds);

  scale := Min(w/fSrcImg.width, h/fSrcImg.height);
  w := Round(fSrcImg.width * scale);
  h := Round(fSrcImg.height * scale);
  l := (RectWidth(FBounds)- w) div 2;
  t := (RectHeight(FBounds)- h) div 2;

  FixAlpha(fSrcImg); //do this before resizing
  img := ImageResize(fSrcImg, w, h); //much better that using STRETCHDIBITS
  bm := Make32BitBitmapFromPxls(img);
  imgCtrl := GetDlgItem(fDialog, ID_IMAGE);

  SetWindowPos(fDialog, 0, l,t,w,h, SWP_NOZORDER or SWP_NOACTIVATE);
  SetWindowPos(imgCtrl, 0, 0,0,w,h, SWP_NOZORDER or SWP_NOACTIVATE);
  oldBm := SendMessage(imgCtrl, STM_SETIMAGE, IMAGE_BITMAP, bm);
  if oldBm <> 0 then DeleteObject(oldBm);
  DeleteObject(bm);
end;
//------------------------------------------------------------------------------

function DlgProc(dlg: HWnd; msg, wPar: WPARAM; lPar: LPARAM): Bool; stdcall;
var
  svgShellExt: TQoiShelExt;
begin
  case msg of
    WM_CTLCOLORDLG, WM_CTLCOLORSTATIC:
      begin
        svgShellExt := Pointer(GetWindowLongPtr(dlg, GWLP_USERDATA));
        if Assigned(svgShellExt) and (svgShellExt.fDarkBrush <> 0) then
          Result := Bool(svgShellExt.fDarkBrush) else
          Result := Bool(GetSysColorBrush(COLOR_WINDOW));
      end;
    else
      Result := False;
  end;
end;
//------------------------------------------------------------------------------

function TQoiShelExt.DoPreview: HRESULT;
var
  qoiBytes  : TArrayOfByte;
  size,dum  : Cardinal;
begin
  result := S_OK;
  if (fParent = 0) or FBounds.IsEmpty then Exit;
  CleanupObjects;

  if not fDarkModeChecked then
    CheckDarkMode;
  //get file contents and put into qoiBytes
  size := GetStreamSize(fStream);
  if size = 0 then Exit;
  SetLength(qoiBytes, size);
  SetStreamPos(fStream, 0);
  fStream.Read(@qoiBytes[0], size, @dum);

  //extract image from qoiBytes and fill fSrcImg
  fSrcImg := ReadQoi(qoiBytes);
  if fSrcImg.pixels = nil then Exit;

  //create the display dialog containing an image control
  fDialog := CreateDialog(hInstance, MAKEINTRESOURCE(1), fParent, @DlgProc);
  SetWindowLongPtr(fDialog, GWLP_USERDATA, NativeInt(self));
  if fDarkModeEnabled then
    fDarkBrush := CreateSolidBrush(darkBkColor);
  //draw and show the display dialog
  RedrawDialog;
  ShowWindow(fDialog, SW_SHOW);
end;
//------------------------------------------------------------------------------

function TQoiShelExt.QueryFocus(var phwnd: HWND): HRESULT;
begin
  phwnd := GetFocus;
  result := S_OK;
end;
//------------------------------------------------------------------------------

function TQoiShelExt.SetFocus: HRESULT;
begin
  result := S_OK;
end;
//------------------------------------------------------------------------------

function TQoiShelExt.SetRect(var prc: TRect): HRESULT;
begin
  FBounds := prc;
  RedrawDialog;
  result := S_OK;
end;
//------------------------------------------------------------------------------

function TQoiShelExt.SetWindow(hwnd: HWND; var prc: TRect): HRESULT;
begin
  if (hwnd <> 0) then fParent := hwnd;
  if (@prc <> nil) then FBounds := prc;
  CleanupObjects;
  result := S_OK;
end;
//------------------------------------------------------------------------------

function TQoiShelExt.TranslateAccelerator(var pmsg: tagMSG): HRESULT;
begin
  result := S_FALSE
end;
//------------------------------------------------------------------------------

function TQoiShelExt.Unload: HRESULT;
begin
  CleanupObjects;
  fStream := nil;
  fParent := 0;
  result := S_OK;
end;
//------------------------------------------------------------------------------

function TQoiShelExt.IInitializeWithStream_Init(const pstream: IStream;
  grfMode: DWORD): HRESULT;
begin
  fStream := nil;
  fStream := pstream;
  result := S_OK;
end;
//------------------------------------------------------------------------------

function TQoiShelExt.GetThumbnail(cx: Cardinal;
  out hbmp: HBITMAP; out at: TWTS_ALPHATYPE): HRESULT;
var
  size, dum : Cardinal;
  w,h       : integer;
  scale     : double;
  img       : TImage32Rec;
  qoiBytes  : TArrayOfByte;
begin
  result := S_FALSE;
  if fStream = nil then Exit;

  //get file contents and put into qoiBytes
  size := GetStreamSize(fStream);
  SetStreamPos(fStream, 0);
  SetLength(qoiBytes, size);
  result := fStream.Read(@qoiBytes[0], size, @dum);
  if not Succeeded(Result) then Exit;

  //extract image from qoiBytes and fill img
  img := ReadQoi(qoiBytes);
  if img.pixels = nil then Exit;
  at := WTSAT_ARGB;

  scale := Min(cx/img.width, cx/img.height);
  w := Round(img.width * scale);
  h := Round(img.height * scale);

  FixAlpha(img); //do this before resizing
  img := ImageResize(img, w, h); //much better that using STRETCHDIBITS
  hbmp := Make32BitBitmapFromPxls(img);
end;

//------------------------------------------------------------------------------
// TWeightedColor
//------------------------------------------------------------------------------

procedure TWeightedColor.Reset;
begin
  fAddCount := 0;
  fAlphaTot := 0;
  fColorTotR := 0;
  fColorTotG := 0;
  fColorTotB := 0;
end;
//------------------------------------------------------------------------------

procedure TWeightedColor.AddWeight(w: Integer);
begin
  inc(fAddCount, w);
end;
//------------------------------------------------------------------------------

procedure TWeightedColor.Add(c: TARGB; w: Integer);
var
  a: Integer;
  argb: TARGB absolute c;
begin
  inc(fAddCount, w);
  a := w * argb.A;
  if a = 0 then Exit;
  inc(fAlphaTot, a);
  inc(fColorTotB, (a * argb.B));
  inc(fColorTotG, (a * argb.G));
  inc(fColorTotR, (a * argb.R));
end;
//------------------------------------------------------------------------------

procedure TWeightedColor.Add(const other: TWeightedColor);
begin
  inc(fAddCount, other.fAddCount);
  inc(fAlphaTot, other.fAlphaTot);
  inc(fColorTotR, other.fColorTotR);
  inc(fColorTotG, other.fColorTotG);
  inc(fColorTotB, other.fColorTotB);
end;
//------------------------------------------------------------------------------

function TWeightedColor.GetColor: TARGB;
var
  invAlpha: double;
  res: TARGB absolute Result;
begin
  if (fAlphaTot <= 0) or (fAddCount <= 0) then
  begin
    result.Color := 0;
    Exit;
  end;
  res.A := Min(255, (fAlphaTot  + (fAddCount shr 1)) div fAddCount);
  //nb: alpha weighting is applied to colors when added,
  //so we now need to div by fAlphaTot here ...
  invAlpha := 1/fAlphaTot;
  res.R := ClampByte(fColorTotR * invAlpha);
  res.G := ClampByte(fColorTotG * invAlpha);
  res.B := ClampByte(fColorTotB * invAlpha);
end;
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------

var
  res: HResult;

initialization
  res := OleInitialize(nil);
  TComObjectFactory.Create(ComServer,
    TQoiShelExt, IID_EXT_ShellExtensions,
    extFile, extDescription, ciMultiInstance, tmApartment);

finalization
  if res = S_OK then OleUninitialize();

end.
