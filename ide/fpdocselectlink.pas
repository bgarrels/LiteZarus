{
 ***************************************************************************
 *                                                                         *
 *   This source is free software; you can redistribute it and/or modify   *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 *   This code is distributed in the hope that it will be useful, but      *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   General Public License for more details.                              *
 *                                                                         *
 *   A copy of the GNU General Public License is available on the World    *
 *   Wide Web at <http://www.gnu.org/copyleft/gpl.html>. You can also      *
 *   obtain it by writing to the Free Software Foundation,                 *
 *   Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.        *
 *                                                                         *
 ***************************************************************************

  Author: Mattias Gaertner
  
  Abstract:
    Dialog used by the fpdoc editor to create a link.
}
unit FPDocSelectLink;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LCLProc, LResources, Forms, Controls, Graphics, Dialogs,
  ExtCtrls, StdCtrls, ButtonPanel, FileUtil, LCLType,
  PackageIntf, ProjectIntf,
  CodeHelp, LazarusIDEStrConsts, PackageSystem, PackageDefs, Laz_DOM;

type

  { TFPDocLinkCompletionItem }

  TFPDocLinkCompletionItem = class
  public
    Text: string;
    Description: string;
    constructor Create(const AText, ADescription: string);
  end;

  { TFPDocLinkCompletionList }

  TFPDocLinkCompletionList = class
  private
    FBGColor: TColor;
    FItemHeight: integer;
    FItems: TFPList; // list of TFPDocLinkCompletionItem
    FPrefix: string;
    FSelected: integer;
    FSelectedBGColor: TColor;
    FSelectedTextColor: TColor;
    FTextColor: TColor;
    FTop: integer;
    FVisibleItems: integer;
    function GetCount: integer;
    function GetItems(Index: integer): TFPDocLinkCompletionItem;
    procedure SetSelected(const AValue: integer);
    procedure SetTop(const AValue: integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure AddPackage(Pkg: TLazPackage);
    procedure AddProjectFile(AFile: TLazProjectFile);
    procedure AddPackageFile(AFile: TPkgFile);
    procedure AddIdentifier(Identifier: string);
    procedure Draw(Canvas: TCanvas; Width, Height: integer);
    property Count: integer read GetCount;
    property Items[Index: integer]: TFPDocLinkCompletionItem read GetItems;
    property ItemHeight: integer read FItemHeight write FItemHeight;// pixel per item
    property VisibleItems: integer read FVisibleItems write FVisibleItems;// visible lines
    property Top: integer read FTop write SetTop;
    property Selected: integer read FSelected write SetSelected;
    property Prefix: string read FPrefix write FPrefix;
    property BGColor: TColor read FBGColor write FBGColor;
    property TextColor: TColor read FTextColor write FTextColor;
    property SelectedBGColor: TColor read FSelectedBGColor write FSelectedBGColor;
    property SelectedTextColor: TColor read FSelectedTextColor write FSelectedTextColor;
  end;

  { TFPDocLinkEditorDlg }

  TFPDocLinkEditorDlg = class(TForm)
    ButtonPanel1: TButtonPanel;
    CompletionBox: TPaintBox;
    TitleEdit: TEdit;
    TitleLabel: TLabel;
    LinkEdit: TEdit;
    LinkLabel: TLabel;
    procedure CompletionBoxPaint(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure LinkEditChange(Sender: TObject);
    procedure LinkEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState
      );
  private
    FStartFPDocFile: TLazFPDocFile;
    fItems: TFPDocLinkCompletionList;
    FSourceFilename: string;
    FStartModuleOwner: TObject;
    function GetLink: string;
    function GetLinkTitle: string;
    procedure SetStartFPDocFile(const AValue: TLazFPDocFile);
    procedure SetLink(const AValue: string);
    procedure SetLinkTitle(const AValue: string);
    procedure SetSourceFilename(const AValue: string);
    procedure SetStartModuleOwner(const AValue: TObject);
    procedure UpdateCompletionBox;
    procedure AddPackagesToCompletion(Prefix: string);
    procedure AddModuleUnits(ModuleOwner: TObject; Prefix: string);
    procedure AddProjectUnits(AProject: TLazProject; Prefix: string);
    procedure AddPackageUnits(APackage: TLazPackage; Prefix: string);
    procedure AddIdentifiers(ModuleOwner: TObject; FPDocFile: TLazFPDocFile;
                             Prefix: string);
    procedure AddSubIdentifiers(Path: string);
  public
    procedure SetLinkAndContext(const ASrcFilename, ATitle, ALink: string;
                      ADocFile: TLazFPDocFile);
    property SourceFilename: string read FSourceFilename write SetSourceFilename;
    property LinkTitle: string read GetLinkTitle write SetLinkTitle;
    property Link: string read GetLink write SetLink;
    property StartFPDocFile: TLazFPDocFile read FStartFPDocFile write SetStartFPDocFile;
    property StartModuleOwner: TObject read FStartModuleOwner write SetStartModuleOwner;
  end;

function ShowFPDocLinkEditorDialog(SrcFilename: string;
  StartFPDocFile: TLazFPDocFile; out Link, LinkTitle: string): TModalResult;

implementation

function ShowFPDocLinkEditorDialog(SrcFilename: string;
  StartFPDocFile: TLazFPDocFile; out Link, LinkTitle: string): TModalResult;
var
  FPDocLinkEditorDlg: TFPDocLinkEditorDlg;
begin
  Link:='';
  LinkTitle:='';
  FPDocLinkEditorDlg:=TFPDocLinkEditorDlg.Create(nil);
  try
    FPDocLinkEditorDlg.SetLinkAndContext(SrcFilename,LinkTitle,Link,StartFPDocFile);
    Result:=FPDocLinkEditorDlg.ShowModal;
    if Result=mrOk then begin
      Link:=FPDocLinkEditorDlg.Link;
      LinkTitle:=FPDocLinkEditorDlg.LinkTitle;
    end;
  finally
    FPDocLinkEditorDlg.Free;
  end;
end;

{ TFPDocLinkEditorDlg }

procedure TFPDocLinkEditorDlg.FormCreate(Sender: TObject);
begin
  Caption:=lisChooseAFPDocLink;
  LinkLabel.Caption:=lisLinkTarget;
  LinkLabel.Hint:=Format(lisExamplesIdentifierTMyEnumEnumUnitnameIdentifierPac,
    [#13, #13, #13, #13]);
  TitleLabel.Caption:=lisTitleLeaveEmptyForDefault;
  
  LinkEdit.Text:='';
  TitleEdit.Text:='';

  // disable return key
  ButtonPanel1.OKButton.Default:=false;

  FItems:=TFPDocLinkCompletionList.Create;

  ActiveControl:=LinkEdit;
end;

procedure TFPDocLinkEditorDlg.FormDestroy(Sender: TObject);
begin
  FreeAndNil(fItems);
end;

procedure TFPDocLinkEditorDlg.CompletionBoxPaint(Sender: TObject);
begin
  fItems.BGColor:=clWindow;
  fItems.TextColor:=clWindowText;
  fItems.SelectedBGColor:=clHighlight;
  fItems.SelectedTextColor:=clHighlightText;
  fItems.ItemHeight:=Canvas.TextHeight('ABCTWSMgqp')+4;
  fItems.VisibleItems:=CompletionBox.ClientHeight div fItems.ItemHeight;
  fItems.Draw(CompletionBox.Canvas,
              CompletionBox.ClientWidth,CompletionBox.ClientHeight);
end;

procedure TFPDocLinkEditorDlg.LinkEditChange(Sender: TObject);
begin
  DebugLn(['TFPDocLinkEditorDlg.LinkEditChange "',LinkEdit.Text,'"']);
  Link:=LinkEdit.Text;
end;

procedure TFPDocLinkEditorDlg.LinkEditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  Handled: Boolean;
begin
  if Shift=[] then begin
    Handled:=true;
    case Key of
    VK_UP:
      if FItems.Selected>0 then begin
        FItems.Selected:=FItems.Selected-1;
        if FItems.Top>fItems.Selected then
          FItems.Top:=fItems.Selected;
        CompletionBox.Invalidate;
      end;
    VK_DOWN:
      if FItems.Selected<fItems.Count-1 then begin
        FItems.Selected:=FItems.Selected+1;
        if FItems.Selected>=fItems.Top+fItems.VisibleItems then
          FItems.Top:=FItems.Top+1;
        CompletionBox.Invalidate;
      end;
    VK_RETURN:
      if (FItems.Selected>=0) and (FItems.Selected<fItems.Count) then
        Link:=FItems.Items[fItems.Selected].Text;
    else
      Handled:=false;
    end;
    if Handled then Key:=VK_UNKNOWN;
  end;
end;

procedure TFPDocLinkEditorDlg.SetSourceFilename(const AValue: string);
var
  Owners: TFPList;
  i: Integer;
begin
  if FSourceFilename=AValue then exit;
  FSourceFilename:=AValue;
  FStartModuleOwner:=nil;
  Owners:=PackageEditingInterface.GetPossibleOwnersOfUnit(FSourceFilename,
    [piosfIncludeSourceDirectories]);
  if Owners=nil then exit;
  try
    for i:=0 to Owners.Count-1 do begin
      if TObject(Owners[i]) is TLazProject then begin
        FStartModuleOwner:=TLazProject(Owners[i]);
      end else if TObject(Owners[i]) is TLazPackage then begin
        if FStartModuleOwner=nil then
          FStartModuleOwner:=TLazPackage(Owners[i]);
      end;
    end;
  finally
    Owners.Free;
  end;
end;

procedure TFPDocLinkEditorDlg.SetStartModuleOwner(const AValue: TObject);
begin
  if FStartModuleOwner=AValue then exit;
  FStartModuleOwner:=AValue;
end;

procedure TFPDocLinkEditorDlg.UpdateCompletionBox;
{
  ToDo:
  empty  : show all packages, all units of current project/package and all identifiers of unit
  #l     : show all packages beginning with the letter l
  #lcl.  : show all units of package lcl
  f      : show all units and all identifiers beginning with the letter f
  forms. : show all identifiers of unit forms and all sub identifiers of identifier forms

  forms.tcontrol.        : show all sub identifiers of identifier tcontrol
  #lcl.forms.            : same as above
  #lcl.forms.tcontrol.   : same as above
}
var
  l: String;
begin
  if FItems=nil then exit;
  fItems.Clear;
  l:=LinkEdit.Text;
  FItems.Prefix:=l;
  DebugLn(['TFPDocLinkEditorDlg.UpdateCompletionBox Prefix="',l,'"']);
  AddSubIdentifiers(l);
  CompletionBox.Invalidate;
end;

procedure TFPDocLinkEditorDlg.AddPackagesToCompletion(Prefix: string);
var
  i: Integer;
  Pkg: TLazPackage;
begin
  for i:=0 to PackageGraph.Count-1 do begin
    Pkg:=PackageGraph.Packages[i];
    if Pkg.LazDocPaths='' then continue;
    if (SysUtils.CompareText(Prefix,copy(Pkg.Name,1,length(Prefix)))=0) then
      fItems.AddPackage(Pkg);
  end;
end;

procedure TFPDocLinkEditorDlg.AddModuleUnits(ModuleOwner: TObject;
  Prefix: string);
var
  AProject: TLazProject;
  APackage: TLazPackage;
begin
  if ModuleOwner=nil then exit;
  if ModuleOwner is TLazProject then begin
    AProject:=TLazProject(ModuleOwner);
    AddProjectUnits(AProject,Prefix);
  end else if ModuleOwner is TLazPackage then begin
    APackage:=TLazPackage(ModuleOwner);
    AddPackageUnits(APackage,Prefix);
  end;
end;

procedure TFPDocLinkEditorDlg.AddProjectUnits(AProject: TLazProject;
  Prefix: string);
var
  i: Integer;
  Filename: String;
  ProjFile: TLazProjectFile;
begin
  for i:=0 to AProject.FileCount-1 do begin
    ProjFile:=AProject.Files[i];
    if ProjFile.IsPartOfProject then begin
      Filename:=ProjFile.Filename;
      if FilenameIsPascalUnit(Filename) then begin
        Filename:=ExtractFileNameOnly(Filename);
        if (CompareFilenames(Prefix,copy(Filename,1,length(Prefix)))=0) then
          fItems.AddProjectFile(ProjFile);
      end;
    end;
  end;
end;

procedure TFPDocLinkEditorDlg.AddPackageUnits(APackage: TLazPackage;
  Prefix: string);
var
  i: Integer;
  PkgFile: TPkgFile;
  Filename: String;
begin
  for i:=0 to APackage.FileCount-1 do begin
    PkgFile:=APackage.Files[i];
    if FilenameIsPascalUnit(PkgFile.Filename) then begin
      Filename:=PkgFile.Filename;
      if FilenameIsPascalUnit(Filename) then begin
        Filename:=ExtractFileNameOnly(Filename);
        if (CompareFilenames(Prefix,copy(Filename,1,length(Prefix)))=0) then
          fItems.AddPackageFile(PkgFile);
      end;
    end;
  end;
end;

procedure TFPDocLinkEditorDlg.AddIdentifiers(ModuleOwner: TObject;
  FPDocFile: TLazFPDocFile; Prefix: string);
var
  DOMNode: TDOMNode;
  ElementName: String;
  p: Integer;
  ModuleName: String;
begin
  if FPDocFile=nil then exit;
  DOMNode:=FPDocFile.GetFirstElement;
  while DOMNode<>nil do begin
    if (DOMNode is TDomElement) then begin
      ElementName:=TDomElement(DOMNode).GetAttribute('name');
      if (SysUtils.CompareText(Prefix,copy(ElementName,1,length(Prefix)))=0)
      then begin
        // same prefix
        // skip sub identifiers
        p:=length(Prefix)+1;
        while (p<=length(ElementName)) and (ElementName[p]<>'.') do inc(p);
        if p>length(ElementName) then begin
          if (FPDocFile<>nil) and (FPDocFile<>StartFPDocFile) then begin
            // different unit
            ElementName:=ExtractFileNameOnly(FPDocFile.Filename)+'.'+ElementName;
          end;
          if (ModuleOwner<>nil) and (ModuleOwner<>StartModuleOwner) then begin
            // different module
            if ModuleOwner is TLazProject then begin
              ModuleName:=lowercase(ExtractFileNameOnly(TLazProject(ModuleOwner).ProjectInfoFile));
            end else if ModuleOwner is TLazPackage then begin
              ModuleName:=TLazPackage(ModuleOwner).Name;
            end;
            if ModuleName<>'' then
              ElementName:=ModuleName+'.'+ElementName
            else
              ElementName:='';
          end;
          if ElementName<>'' then
            FItems.AddIdentifier(ElementName);
        end;
      end;
    end;
    DOMNode:=DOMNode.NextSibling;
  end;
end;

procedure TFPDocLinkEditorDlg.AddSubIdentifiers(Path: string);
var
  p: LongInt;
  Prefix: String;
  HelpResult: TCodeHelpParseResult;
  ModuleOwner: TObject;
  FPDocFile: TLazFPDocFile;
  DOMNode: TDOMNode;
  CacheWasUsed: boolean;
  DOMElement: TDOMElement;
begin
  p:=length(Path);
  while (p>0) and (Path[p]<>'.') do dec(p);
  Prefix:=copy(Path,p+1,length(Path));
  Path:=copy(Path,1,p-1);
  if p<1 then begin
    // empty  : show all packages, all units of current project/package and all identifiers of unit
    // #l     : show all packages beginning with the letter l
    // f      : show all units and all identifiers beginning with the letter f
    if (Prefix='') or (Prefix[1]='#') then
      AddPackagesToCompletion(copy(Prefix,2,length(Prefix)));
    if (Prefix='') or (Prefix[1]<>'#') then begin
      AddModuleUnits(StartModuleOwner,Prefix);
      AddIdentifiers(StartModuleOwner,StartFPDocFile,Prefix);
    end;
  end else begin
    // sub identifier
    DebugLn(['TFPDocLinkEditorDlg.AddSubIdentifiers searching context ..']);
    HelpResult:=CodeHelpBoss.GetLinkedFPDocNode(StartFPDocFile,nil,Path,
      [chofUpdateFromDisk,chofQuiet],ModuleOwner,FPDocFile,DOMNode,CacheWasUsed);
    if HelpResult<>chprSuccess then exit;
    DebugLn(['TFPDocLinkEditorDlg.AddSubIdentifiers context found: ModuleOwner=',DbgSName(ModuleOwner),' FPDocFile=',FPDocFile<>nil,' DOMNode=',DOMNode<>nil]);
    if DOMNode is TDomElement then begin
      DOMElement:=TDomElement(DOMNode);
      AddIdentifiers(ModuleOwner,FPDocFile,DOMElement.GetAttribute('name')+'.'+Prefix);
    end else if FPDocFile<>nil then begin
      AddIdentifiers(ModuleOwner,FPDocFile,Prefix);
    end else if ModuleOwner<>nil then begin
      if ModuleOwner is TLazPackage then
        AddPackageUnits(TLazPackage(ModuleOwner),Prefix)
      else if ModuleOwner is TLazProject then
        AddProjectUnits(TLazProject(ModuleOwner),Prefix)
    end;
  end;
end;

procedure TFPDocLinkEditorDlg.SetLinkAndContext(const ASrcFilename, ATitle,
  ALink: string; ADocFile: TLazFPDocFile);
begin
  StartFPDocFile:=ADocFile;
  fSourceFilename:=ASrcFilename;
  LinkTitle:=ATitle;
  Link:=ALink;
  UpdateCompletionBox;
end;

function TFPDocLinkEditorDlg.GetLinkTitle: string;
begin
  Result:=TitleEdit.Text;
end;

procedure TFPDocLinkEditorDlg.SetStartFPDocFile(const AValue: TLazFPDocFile);
begin
  if FStartFPDocFile=AValue then exit;
  FStartFPDocFile:=AValue;
  FStartModuleOwner:=CodeHelpBoss.FindModuleOwner(FStartFPDocFile);
end;

function TFPDocLinkEditorDlg.GetLink: string;
begin
  Result:=LinkEdit.Text;
end;

procedure TFPDocLinkEditorDlg.SetLink(const AValue: string);
begin
  if FItems=nil then exit;
  if AValue=fItems.Prefix then exit;
  LinkEdit.Text:=AValue;
  UpdateCompletionBox;
end;

procedure TFPDocLinkEditorDlg.SetLinkTitle(const AValue: string);
begin
  TitleEdit.Text:=AValue;
end;

{ TFPDocLinkCompletionList }

function TFPDocLinkCompletionList.GetCount: integer;
begin
  Result:=FItems.Count;
end;

function TFPDocLinkCompletionList.GetItems(Index: integer
  ): TFPDocLinkCompletionItem;
begin
  Result:=TFPDocLinkCompletionItem(FItems[Index]);
end;

procedure TFPDocLinkCompletionList.SetSelected(const AValue: integer);
begin
  if FSelected=AValue then exit;
  FSelected:=AValue;
end;

procedure TFPDocLinkCompletionList.SetTop(const AValue: integer);
begin
  if FTop=AValue then exit;
  FTop:=AValue;
end;

constructor TFPDocLinkCompletionList.Create;
begin
  FItems:=TFPList.Create;
end;

destructor TFPDocLinkCompletionList.Destroy;
begin
  Clear;
  FreeAndNil(FItems);
  inherited Destroy;
end;

procedure TFPDocLinkCompletionList.Clear;
var
  i: Integer;
begin
  for i:=0 to FItems.Count-1 do TObject(FItems[i]).Free;
  FItems.Clear;
  FSelected:=0;
  FTop:=0;
end;

procedure TFPDocLinkCompletionList.AddPackage(Pkg: TLazPackage);
begin
  FItems.Add(TFPDocLinkCompletionItem.Create('#'+Pkg.Name,'package '+Pkg.IDAsString));
end;

procedure TFPDocLinkCompletionList.AddProjectFile(AFile: TLazProjectFile);
begin
  FItems.Add(TFPDocLinkCompletionItem.Create(
    ExtractFileNameOnly(AFile.Filename),'project unit'));
end;

procedure TFPDocLinkCompletionList.AddPackageFile(AFile: TPkgFile);
begin
  FItems.Add(TFPDocLinkCompletionItem.Create(
    ExtractFileNameOnly(AFile.Filename),'package unit'));
end;

procedure TFPDocLinkCompletionList.AddIdentifier(Identifier: string);
begin
  FItems.Add(TFPDocLinkCompletionItem.Create(Identifier,'identifier'));
end;

procedure TFPDocLinkCompletionList.Draw(Canvas: TCanvas; Width, Height: integer);
var
  i: LongInt;
  y: Integer;
  dy: LongInt;
  Item: TFPDocLinkCompletionItem;
  s: String;
begin
  DebugLn(['TFPDocLinkCompletionList.Draw ',Width,' ',Height,' Count=',Count]);
  i:=Top;
  y:=0;
  dy:=ItemHeight;
  while (y<Height) and (i<Count) do begin
    Item:=Items[i];
    Canvas.Brush.Style:=bsSolid;
    Canvas.Font.Style:=[];
    if i=Selected then begin
      Canvas.Brush.Color:=SelectedBGColor;
      Canvas.Font.Color:=SelectedTextColor;
    end else begin
      Canvas.Brush.Color:=BGColor;
      Canvas.Font.Color:=TextColor;
    end;
    Canvas.FillRect(0,y,Width,y+dy);
    s:=Item.Text;
    Canvas.TextOut(2,y+2,s);
    s:=Item.Description;
    Canvas.TextOut(152,y+2,s);
    inc(y,dy);
    inc(i);
  end;
  if y<Height then begin
    Canvas.Brush.Color:=BGColor;
    Canvas.FillRect(0,y,Width,Height);
  end;
end;

{ TFPDocLinkCompletionItem }

constructor TFPDocLinkCompletionItem.Create(const AText, ADescription: string);
begin
  Text:=AText;
  Description:=ADescription;
end;

initialization
  {$I fpdocselectlink.lrs}

end.

