object Form1: TForm1
  Left = 448
  Top = 248
  Caption = 'Test PNG/QOI'
  ClientHeight = 458
  ClientWidth = 488
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Arial'
  Font.Style = []
  Menu = MainMenu1
  OldCreateOrder = True
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  PixelsPerInch = 96
  TextHeight = 15
  object image: TImage
    Left = 0
    Top = 66
    Width = 488
    Height = 373
    Align = alClient
    Stretch = True
    ExplicitHeight = 374
  end
  object Panel1: TPanel
    Left = 0
    Top = 0
    Width = 488
    Height = 66
    Align = alTop
    TabOrder = 0
    object btnPNG: TButton
      Left = 14
      Top = 14
      Width = 107
      Height = 35
      Caption = 'Time &PNG'
      Enabled = False
      TabOrder = 0
      OnClick = btnPNGClick
    end
    object btnConvertFolder: TButton
      Left = 324
      Top = 14
      Width = 144
      Height = 35
      Caption = '&Convert PNGs ...'
      TabOrder = 2
      OnClick = btnConvertFolderClick
    end
    object btnQoi: TButton
      Left = 137
      Top = 14
      Width = 107
      Height = 35
      Caption = 'Time &QOI'
      Enabled = False
      TabOrder = 1
      OnClick = btnQoiClick
    end
  end
  object StatusBar1: TStatusBar
    Left = 0
    Top = 439
    Width = 488
    Height = 19
    Panels = <>
    SimplePanel = True
  end
  object MainMenu1: TMainMenu
    Left = 232
    Top = 120
    object File1: TMenuItem
      Caption = '&File'
      object Open1: TMenuItem
        Caption = '&Open ...'
        ShortCut = 16463
        OnClick = Open1Click
      end
      object N1: TMenuItem
        Caption = '-'
      end
      object mnuExit: TMenuItem
        Caption = 'E&xit'
        ShortCut = 27
        OnClick = mnuExitClick
      end
    end
  end
  object OpenDialog1: TOpenDialog
    Filter = 'Image Files (*.BMP,*.PNG,*.JPG,*.QOI)|*.BMP;*.PNG; *.JPG;*.QOI;'
    Left = 176
    Top = 120
  end
  object FileOpenDialog: TFileOpenDialog
    FavoriteLinks = <>
    FileTypes = <>
    Options = [fdoPickFolders, fdoForceFileSystem, fdoPathMustExist]
    Left = 296
    Top = 128
  end
end
