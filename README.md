# TQoiImage
Delphi support for QOI images.<br><br>

QOI - The “Quite OK Image Format” for fast, lossless image compression<br>
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
    Image1.Picture.Assign(qoi);
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

