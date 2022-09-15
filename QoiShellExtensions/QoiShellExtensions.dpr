library QoiShellExtensions;

(*******************************************************************************
* Author    :  Angus Johnson                                                   *
* Version   :  1.0                                                             *
* Date      :  19 January 2022                                                 *
* Website   :  http://www.angusj.com                                           *
* Copyright :  Angus Johnson 2022                                              *
*                                                                              *
* Purpose   :  64bit Windows Explorer Preview Handler for QOI image files      *
*                                                                              *
* License   :  Use, modification & distribution is subject to                  *
*              Boost Software License Ver 1                                    *
*              http://www.boost.org/LICENSE_1_0.txt                            *
*******************************************************************************)

uses
  Windows,
  Winapi.ShlObj,
  Winapi.ActiveX,
  System.Classes,
  System.SysUtils,
  System.Win.ComServ,
  System.Win.Registry,
  QoiPreview in 'QoiPreview.pas',
  QoiReader in 'QoiReader.pas';

{$R *.res}

const
  sSurrogateId = '{6D2B5079-2F0B-48DD-AB7F-97CEC514D30B}'; //64bit

function GetModuleName: string;
var
  i: integer;
begin
  SetLength(Result, MAX_PATH);
  i := GetModuleFileName(hInstance, @Result[1], MAX_PATH);
  SetLength(Result, i);
end;
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------

function DllRegisterServer: HResult; stdcall;
var
  reg: TRegistry;
begin
  Result := E_UNEXPECTED; //will fail if not ADMIN

  reg := TRegistry.Create(KEY_ALL_ACCESS);
  try
    reg.RootKey := HKEY_CLASSES_ROOT;
    if not reg.OpenKey(extension, true) then Exit;
    reg.WriteString('', extFile);
    reg.CloseKey;

    if reg.OpenKey(extFile+'\Clsid', true) then
    begin
      reg.WriteString('', SID_EXT_ShellExtensions);
      reg.CloseKey;
    end;

    //REGISTER PREVIEW HANDLER
    if reg.OpenKey(extFile+'\ShellEx\'+SID_IPreviewHandler, true) then
    begin
      reg.WriteString('', SID_EXT_ShellExtensions);
      reg.CloseKey;
    end;
    //REGISTER THUMBNAIL PROVIDER
    if reg.OpenKey(extFile+'\ShellEx\'+SID_IThumbnailProvider, true) then
    begin
      reg.WriteString('', SID_EXT_ShellExtensions);
      reg.CloseKey;
    end;

    if not reg.OpenKey('CLSID\'+ SID_EXT_ShellExtensions, true) then Exit;
    reg.WriteString('', extDescription);
    reg.WriteString('AppID', sSurrogateId);
    reg.CloseKey;

    reg.OpenKey('CLSID\'+ SID_EXT_ShellExtensions+'\InProcServer32', true);
    reg.WriteString('', GetModuleName);
    reg.WriteString('ThreadingModel', 'Apartment');
    reg.CloseKey;

    reg.OpenKey('CLSID\' + SID_EXT_ShellExtensions + '\ProgId', true);
    reg.WriteString('', extFile);
    reg.CloseKey;

    reg.RootKey := HKEY_LOCAL_MACHINE;
    if reg.OpenKey('SOFTWARE\Microsoft\Windows\'+
      'CurrentVersion\PreviewHandlers', true) then
    begin
      reg.WriteString(SID_EXT_ShellExtensions, extDescription);
      reg.CloseKey;
    end;

  finally
    reg.Free;
  end;

  //Invalidate the shell's cache so any .qoi files viewed
  //before registering won't show blank images.
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nil, nil);

  Result := S_OK;
end;

function DllUnregisterServer: HResult; stdcall;
var
  reg: TRegistry;
begin
  reg := TRegistry.Create(KEY_ALL_ACCESS);
  try
    reg.RootKey := HKEY_LOCAL_MACHINE;
    if reg.OpenKey('SOFTWARE\Microsoft\Windows\'+
      'CurrentVersion\PreviewHandlers', true) and
        reg.ValueExists(SID_EXT_ShellExtensions) then
          reg.DeleteValue(SID_EXT_ShellExtensions);

    reg.RootKey := HKEY_CLASSES_ROOT;
    reg.DeleteKey('CLSID\'+SID_EXT_ShellExtensions);
    reg.DeleteKey(extFile+'\ShellEx\'+SID_IPreviewHandler);
    reg.DeleteKey(extFile+'\ShellEx\'+SID_IThumbnailProvider);
    reg.DeleteKey(extFile+'\Clsid');
  finally
    reg.Free;
  end;
  Result := S_OK;
end;

exports
  DllRegisterServer,
  DllUnregisterServer,
  DllGetClassObject,
  DllCanUnloadNow;

begin
end.
