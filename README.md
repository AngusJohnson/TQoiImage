# TQoiImage
Delphi support for QOI images.

For more about QOI images see<br>
https://github.com/phoboslab/qoi


Example:

<pre><code>
<b>uses</b> Vcl.Imaging.QOI;
...
<b>var</b>
  qoi: TQoiImage;
<b>begin</b>
  qoi := TQoiImage.Create;
  <b>try</b>
    qoi.LoadFromFile('..\..\dice.qoi');
    
    <i>//copy (draw) the qoi image onto a TImage component</i>
    <b>with</b> Image1.Picture.Bitmap <b>do</b>
    <b>begin</b>
      SetSize(qoi.Width, qoi.Height);
      PixelFormat := pf32bit;
      Canvas.Brush.Color := clBtnFace;
      Canvas.FillRect(Rect(0, 0, Width, Height));    
      Canvas.Draw(0,0, qoi);
    <b>end</b>;
    
  <b>finally</b>
    qoi.Free;
  <b>end</b>;

  qoi := TQoiImage.Create;
  <b>try</b>
    <i>//TQoiImage objects can load from 
    //and save to both QOI and BMP file formats</i>
    qoi.LoadFromFile('..\..\dice2.bmp');
    qoi.SaveToFile('..\..\dice2.qoi');
  <b>finally</b>
    qoi.Free;
  <b>end</b>;
</code></pre>

