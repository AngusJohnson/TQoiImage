# TQoiImage
Delphi support for QOI images.

For more about QOI images see<br>
https://github.com/phoboslab/qoi


Example:

<pre><code>
uses Vcl.Imaging.QOI;
...
var
  qoi: TQoiImage;
begin
  qoi := TQoiImage.Create;
  try
    qoi.LoadFromFile('..\..\dice.qoi');
    
    //copy (draw) the qoi image onto a TImage component
    with Image1.Picture.Bitmap do
    begin
      SetSize(qoi.Width, qoi.Height);
      PixelFormat := pf32bit;
      Canvas.Brush.Color := clBtnFace;
      Canvas.FillRect(Rect(0, 0, Width, Height));    
      Canvas.Draw(0,0, qoi);
    end;
    
  finally
    qoi.Free;
  end;

  qoi := TQoiImage.Create;
  try
    //nb: TQoiImage objects can load from and 
    //save to both QOI and BMP file formats
    qoi.LoadFromFile('..\..\dice2.bmp');
    qoi.SaveToFile('..\..\dice2.qoi');
  finally
    qoi.Free;
  end;
</code></pre>

