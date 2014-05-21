{
 *****************************************************************************
  See the file COPYING.modifiedLGPL.txt, included in this distribution,
  for details about the license.
 *****************************************************************************

  Author:
    Joost van der Sluis

  Contributors:
    x2nie

  Abstract:
    Change the resource type (e.g. .lfm) of forms.
    Every unit can have one resource file. Default is .lfm.
    This unit allows to define other formats, like .xib.
}
unit UnitResources;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LCLMemManager, Forms;

type

  { TUnitResourcefileFormat }

  TUnitResourcefileFormat = class
  public
    class function  DefaultResourceFileExt: string; virtual; abstract;
    class function  FindResourceDirective(Source: TObject;
      out AResourceFileExt: string ): boolean; virtual; abstract;
    class function  ResourceDirectiveFilename: string; virtual;
    class function  GetUnitResourceFilename(AUnitFilename: string; Loading: boolean): string; virtual; 
    class procedure TextStreamToBinStream(ATxtStream, ABinStream: TExtMemoryStream); virtual; abstract;
    class procedure BinStreamToTextStream(ABinStream, ATextStream: TExtMemoryStream); virtual; abstract;
    class function  GetClassNameFromStream(s: TStream; out IsInherited: Boolean): shortstring; virtual; abstract;
    class function  CreateReader(s: TStream; var DestroyDriver: boolean): TReader; virtual; abstract;
    class function  CreateWriter(s: TStream; var DestroyDriver: boolean): TWriter; virtual; abstract;
    class function  QuickCheckResourceBuffer(PascalBuffer, LFMBuffer: TObject; // TCodeBuffer
      out LFMType, LFMComponentName, LFMClassName: string;
      out LCLVersion: string;
      out MissingClasses: TStrings// e.g. MyFrame2:TMyFrame
      ): TModalResult; virtual; abstract;
  end;
  TUnitResourcefileFormatClass = class of TUnitResourcefileFormat;
  TUnitResourcefileFormatArr = array of TUnitResourcefileFormatClass;

var
  LFMUnitResourceFileFormat: TUnitResourcefileFormatClass = nil;// set by IDE

procedure RegisterUnitResourcefileFormat(AResourceFileFormat: TUnitResourcefileFormatClass);
function GetUnitResourcefileFormats: TUnitResourcefileFormatArr;

implementation

var
  GUnitResourcefileFormats: TUnitResourcefileFormatArr;

procedure RegisterUnitResourcefileFormat(AResourceFileFormat: TUnitResourcefileFormatClass);
begin
  SetLength(GUnitResourcefileFormats, length(GUnitResourcefileFormats)+1);
  GUnitResourcefileFormats[high(GUnitResourcefileFormats)] := AResourceFileFormat;
end;

function GetUnitResourcefileFormats: TUnitResourcefileFormatArr;
begin
  result := GUnitResourcefileFormats;
end;

{ TUnitResourcefileFormat }

{class function TUnitResourcefileFormat.FindResourceDirective(
  Source: TObject; out AResourceFileExt: string): boolean;
begin
  AResourceFileExt := EmptyStr;
  result := FindResourceDirective(Source);
  if result then
    AResourceFileExt := DefaultResourceFileExt;
end;}

class function TUnitResourcefileFormat.GetUnitResourceFilename(
  AUnitFilename: string; Loading: boolean): string;
begin
  result := ChangeFileExt(AUnitFilename,DefaultResourceFileExt);
end;

class function TUnitResourcefileFormat.ResourceDirectiveFilename: string;
begin
  result := '*' + DefaultResourceFileExt;
end;

end.

