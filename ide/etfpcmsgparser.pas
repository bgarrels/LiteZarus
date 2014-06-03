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
    Parser for Free Pascal Compiler output.
}
unit etFPCMsgParser;

{$IFNDEF EnableNewExtTools}{$ERROR Wrong}{$ENDIF}

{$mode objfpc}{$H+}

{off $DEFINE VerboseQuickFixUnitNotFoundPosition}

interface

uses
  Classes, SysUtils, strutils, FileProcs, KeywordFuncLists, IDEExternToolIntf,
  PackageIntf, LazIDEIntf, ProjectIntf, IDEUtils, CompOptsIntf,
  CodeToolsFPCMsgs, CodeToolsStructs, CodeCache, CodeToolManager,
  DirectoryCacher, BasicCodeTools, DefineTemplates, LazUTF8, FileUtil,
  LConvEncoding, TransferMacros, etMakeMsgParser, EnvironmentOpts;

const
  FPCMsgIDLogo = 11023;
  FPCMsgIDCantFindUnitUsedBy = 10022;
  FPCMsgIDLinking = 9015;
  FPCMsgIDErrorWhileLinking = 9013;
  FPCMsgIDErrorWhileCompilingResources = 9029;
  FPCMsgIDCallingResourceCompiler = 9028;
  FPCMsgIDThereWereErrorsCompiling = 10026;
  FPCMsgIDIdentifierNotFound = 5000;

  FPCMsgAttrWorkerDirectory = 'WD';
  FPCMsgAttrMissingUnit = 'MissingUnit';
  FPCMsgAttrUsedByUnit = 'UsedByUnit';
type
  TFPCMsgFilePool = class;

  { TFPCMsgFilePoolItem }

  TFPCMsgFilePoolItem = class
  private
    FMsgFile: TFPCMsgFile;
    FFilename: string;
    FPool: TFPCMsgFilePool;
    FLoadedFileAge: integer;
    fUseCount: integer;
  public
    constructor Create(aPool: TFPCMsgFilePool; const aFilename: string);
    destructor Destroy; override;
    property Pool: TFPCMsgFilePool read FPool;
    property Filename: string read FFilename;
    property LoadedFileAge: integer read FLoadedFileAge;
    function GetMsg(ID: integer): TFPCMsgItem;
    property MsgFile: TFPCMsgFile read FMsgFile;
    property UseCount: integer read fUseCount;
  end;

  TETLoadFileEvent = procedure(aFilename: string; out s: string) of object;

  { TFPCMsgFilePool }

  TFPCMsgFilePool = class(TComponent)
  private
    fCritSec: TRTLCriticalSection;
    FDefaultEnglishFile: string;
    FDefaultTranslationFile: string;
    FFiles: TFPList; // list of TFPCMsgFilePoolItem sorted for loaded
    FOnLoadFile: TETLoadFileEvent;
    fPendingLog: TStrings;
    fMsgFileStamp: integer;
    fCurrentEnglishFile: string; // valid only if fMsgFileStamp=CompilerParseStamp
    fCurrentTranslationFile: string; // valid only if fMsgFileStamp=CompilerParseStamp
    procedure Log(Msg: string; AThread: TThread);
    procedure LogSync;
    procedure SetDefaultEnglishFile(AValue: string);
    procedure SetDefaultTranslationFile(AValue: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function LoadCurrentEnglishFile(UpdateFromDisk: boolean;
      AThread: TThread): TFPCMsgFilePoolItem; // don't forget UnloadFile
    function LoadFile(aFilename: string; UpdateFromDisk: boolean;
      AThread: TThread): TFPCMsgFilePoolItem; // don't forget UnloadFile
    procedure UnloadFile(var aFile: TFPCMsgFilePoolItem);
    procedure EnterCriticalsection;
    procedure LeaveCriticalSection;
    procedure GetMsgFileNames(CompilerFilename, TargetOS, TargetCPU: string;
      out anEnglishFile, aTranslationFile: string); // (main thread)
    property DefaultEnglishFile: string read FDefaultEnglishFile write SetDefaultEnglishFile;
    property DefaulTranslationFile: string read FDefaultTranslationFile write SetDefaultTranslationFile;
    property OnLoadFile: TETLoadFileEvent read FOnLoadFile write FOnLoadFile; // (main or workerthread)
  end;

  { TPatternToMsgID }

  TPatternToMsgID = class
  public
    Pattern: string;
    MsgID: integer;
  end;

  { TPatternToMsgIDs }

  TPatternToMsgIDs = class
  private
    fItems: array of TPatternToMsgID;
    function IndexOf(Pattern: PChar; Insert: boolean): integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Add(Pattern: string; MsgID: integer);
    procedure AddLines(const Lines: string; MsgID: integer);
    function LineToMsgID(p: PChar): integer; // 0 = not found
    procedure WriteDebugReport;
    procedure ConsistencyCheck;
  end;

  { TIDEFPCParser }

  TIDEFPCParser = class(TFPCParser)
  private
    fMsgID: Integer; // current message id given by ReadLine (-vq)
    fOutputIndex: integer; // current OutputIndex given by ReadLine
    fLineToMsgID: TPatternToMsgIDs;
    fLastWorkerImprovedMessage: array[boolean] of integer;
    fLastSource: TCodeBuffer;
    fFileExists: TFilenameToPointerTree;
    fIncludePathValidForWorkerDir: string;
    fIncludePath: string; // only valid if fIncludePathValidForWorkerDir=Tool.WorkerDirectory
    fMsgItemUnitNotUsed: TFPCMsgItem;
    fMsgItemCantFindUnitUsedBy: TFPCMsgItem;
    fMsgItemCompilationAborted: TFPCMsgItem;
    fMsgItemThereWereErrorsCompiling: TFPCMsgItem;
    fMsgItemIdentifierNotFound: TFPCMsgItem;
    fMsgItemErrorWhileLinking: TFPCMsgItem;
    fMsgItemErrorWhileCompilingResources: TFPCMsgItem;
    fMissingFPCMsgItem: TFPCMsgItem;
    function FileExists(const Filename: string; aSynchronized: boolean): boolean;
    function CheckForMsgId(p: PChar): boolean; // (MsgId) message
    function CheckForFileLineColMessage(p: PChar): boolean; // the normal messages: filename(y,x): Hint: ..
    function CheckForGeneralMessage(p: PChar): boolean; // Fatal: .., Error: ..., Panic: ..
    function CheckForInfos(p: PChar): boolean;
    function CheckForCompilingState(p: PChar): boolean; // Compiling ..
    function CheckForAssemblingState(p: PChar): boolean; // Assembling ..
    function CheckForLinesCompiled(p: PChar): boolean; // ..lines compiled..
    function CheckForExecutableInfo(p: PChar): boolean;
    function CheckForLineProgress(p: PChar): boolean; // 600 206.521/231.648 Kb Used
    function CheckForRecompilingChecksumChangedMessages(p: PChar): boolean;
    function CheckForLoadFromUnit(p: PChar): Boolean;
    function CheckForWindresErrors(p: PChar): boolean;
    function CreateMsgLine: TMessageLine;
    procedure AddLinkingMessages;
    procedure AddResourceMessages;
    procedure ImproveMsgHiddenByIDEDirective(const SourceOK: Boolean;
      var MsgLine: TMessageLine);
    procedure ImproveMsgSenderNotUsed(aSynchronized: boolean; MsgLine: TMessageLine);
    procedure ImproveMsgUnitNotUsed(aSynchronized: boolean; MsgLine: TMessageLine);
    procedure ImproveMsgUnitNotFound(aSynchronized: boolean;
      MsgLine: TMessageLine);
    procedure ImproveMsgLinkerUndefinedReference(aSynchronized: boolean;
      MsgLine: TMessageLine);
    procedure Translate(p: PChar; MsgItem, TranslatedItem: TFPCMsgItem;
      out TranslatedMsg: String; out MsgType: TMessageLineUrgency);
    function LongenFilename(MsgLine: TMessageLine; aFilename: string): string; // (worker thread)
  public
    DirectoryStack: TStrings;
    MsgFilename: string; // e.g. /path/to/fpcsrc/compiler/msg/errore.msg
    MsgFile: TFPCMsgFilePoolItem;
    TranslationFilename: string; // e.g. /path/to/fpcsrc/compiler/msg/errord.msg
    TranslationFile: TFPCMsgFilePoolItem;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Init; override; // called after macros resolved, before starting thread (main thread)
    procedure InitReading; override; // called if process started, before first line (worker thread)
    procedure Done; override; // called after process stopped (worker thread)
    procedure ReadLine(Line: string; OutputIndex: integer; var Handled: boolean); override;
    procedure AddMsgLine(MsgLine: TMessageLine); override;
    procedure ImproveMessages(aSynchronized: boolean); override;
    function GetFPCMsgIDPattern(MsgID: integer): string; override;
    function IsMsgID(MsgLine: TMessageLine; MsgID: integer;
      var Item: TFPCMsgItem): boolean;
    class function IsSubTool(const SubTool: string): boolean; override;
    class function DefaultSubTool: string; override;
    class function GetMsgPattern(SubTool: string; MsgID: integer): string;
      override;
    class function GetMsgHint(SubTool: string; MsgID: integer): string;
      override;
    class function Priority: integer; override;
    class function MsgLineIsId(Msg: TMessageLine; MsgId: integer;
      out Value1, Value2: string): boolean; override;
    class function GetFPCMsgPattern(Msg: TMessageLine): string; override;
    class function GetFPCMsgValue1(Msg: TMessageLine): string; override;
    class function GetFPCMsgValues(Msg: TMessageLine; out Value1, Value2: string): boolean; override;
  end;

var
  FPCMsgFilePool: TFPCMsgFilePool = nil;

// thread safe
function FPCMsgToMsgUrgency(Msg: TFPCMsgItem): TMessageLineUrgency;
function FPCMsgTypeToUrgency(const Typ: string): TMessageLineUrgency;
function TranslateFPCMsg(const Src, SrcPattern, TargetPattern: string): string;
function FPCMsgFits(const Msg, Pattern: string;
  VarStarts: PPChar = nil; VarEnds: PPChar = nil // 10 PChars
  ): boolean;
function GetFPCMsgValue1(const Src, Pattern: string; out Value1: string): boolean;
function GetFPCMsgValues(Src, Pattern: string; out Value1, Value2: string): boolean;

// not thread safe
function IsFileInIDESrcDir(Filename: string): boolean; // (main thread)

procedure RegisterFPCParser;

implementation

function FPCMsgTypeToUrgency(const Typ: string): TMessageLineUrgency;
begin
  Result:=mluNone;
  if (Typ='') or (length(Typ)<>1) then exit;
  case UpChars[Typ[1]] of
  'F': Result:=mluFatal;
  'E': Result:=mluError;
  'W': Result:=mluWarning;
  'N': Result:=mluNote;
  'H': Result:=mluHint;
  'I': Result:=mluVerbose;  // info
  'L': Result:=mluProgress; // line number
  'C': Result:=mluVerbose;  // conditional: like IFDEFs
  'U': Result:=mluVerbose2; // used: found files
  'T': Result:=mluVerbose3; // tried: tried paths, general information
  'D': Result:=mluDebug;
  'X': Result:=mluProgress; // e.g. Size of Code
  'O': Result:=mluProgress; // e.g., "press enter to continue"
  else
    Result:=mluNone;
  end;
end;

function FPCMsgToMsgUrgency(Msg: TFPCMsgItem): TMessageLineUrgency;
begin
  Result:=mluNone;
  if Msg=nil then exit;
  Result:=FPCMsgTypeToUrgency(Msg.ShownTyp);
  if Result<>mluNone then exit;
  Result:=FPCMsgTypeToUrgency(Msg.Typ);
  if Result=mluNone then begin
    //debugln(['FPCMsgToMsgUrgency Msg.ShownTyp="',Msg.ShownTyp,'" Msg.Typ="',Msg.Typ,'"']);
    Result:=mluVerbose3;
  end;
end;

function IsFPCMsgVar(p: PChar): boolean; inline;
begin
  Result:=(p^='$') and (p[1] in ['0'..'9']);
end;

function IsFPCMsgEndOrVar(p: PChar): boolean; inline;
begin
  Result:=(p^=#0) or IsFPCMsgVar(p);
end;

function TranslateFPCMsg(const Src, SrcPattern, TargetPattern: string): string;
{ for example:
  Src='A lines compiled, B sec C'
  SrcPattern='$1 lines compiled, $2 sec $3'
  TargetPattern='$1 Zeilen uebersetzt, $2 Sekunden $3'

  Result='A Zeilen uebersetzt, B Sekunden C'
}
var
  SrcPos: PChar;
  TargetPatPos: PChar;
  TargetPos: PChar;
  SrcVarStarts, SrcVarEnds: array[0..9] of PChar;
  VarUsed: array[0..9] of integer;
  i: Integer;
begin
  Result:='';
  {$IFDEF VerboseFPCTranslate}
  debugln(['TranslateFPCMsg Src="',Src,'" SrcPattern="',SrcPattern,'" TargetPattern="',TargetPattern,'"']);
  {$ENDIF}
  if (Src='') or (SrcPattern='') or (TargetPattern='') then exit;

  if not FPCMsgFits(Src,SrcPattern,@SrcVarStarts[0],@SrcVarEnds[0]) then
    exit;

  for i:=Low(SrcVarStarts) to high(SrcVarStarts) do
    VarUsed[i]:=0;

  // create Target
  SetLength(Result,length(TargetPattern)+length(Src));
  TargetPatPos:=PChar(TargetPattern);
  TargetPos:=PChar(Result);
  while TargetPatPos^<>#0 do begin
    //debugln(['TranslateFPCMsg Target ',dbgs(Pointer(TargetPatPos)),' ',ord(TargetPatPos^),' TargetPatPos="',TargetPatPos,'"']);
    if IsFPCMsgVar(TargetPatPos) then begin
      // insert variable
      inc(TargetPatPos);
      i:=ord(TargetPatPos^)-ord('0');
      inc(TargetPatPos);
      if SrcVarStarts[i]<>nil then begin
        inc(VarUsed[i]);
        if VarUsed[i]>1 then begin
          // variable is used more than once => realloc result
          dec(TargetPos,{%H-}PtrUInt(PChar(Result)));
          SetLength(Result,length(Result)+SrcVarEnds[i]-SrcVarStarts[i]);
          inc(TargetPos,{%H-}PtrUInt(PChar(Result)));
        end;
        SrcPos:=SrcVarStarts[i];
        while SrcPos<SrcVarEnds[i] do begin
          TargetPos^:=SrcPos^;
          inc(TargetPos);
          inc(SrcPos);
        end;
      end;
    end else begin
      // copy text from TargetPattern
      TargetPos^:=TargetPatPos^;
      inc(TargetPatPos);
      inc(TargetPos);
    end;
  end;
  SetLength(Result,TargetPos-PChar(Result));
  if Result<>'' then
    UTF8FixBroken(PChar(Result));

  {$IFDEF VerboseFPCTranslate}
  debugln(['TranslateFPCMsg Result="',Result,'"']);
  {$ENDIF}
end;

function FPCMsgFits(const Msg, Pattern: string; VarStarts: PPChar;
  VarEnds: PPChar): boolean;
{ for example:
  Src='A lines compiled, B sec C'
  SrcPattern='$1 lines compiled, $2 sec $3'

  VarStarts and VarEnds can be nil.
  If you need the boundaries of the parameters allocate VarStarts and VarEnds as
    VarStarts:=GetMem(SizeOf(PChar)*10);
    VarEnds:=GetMem(SizeOf(PChar)*10);
  VarStarts[0] will be $0, VarStarts[1] will be $1 and so forth

}
var
  MsgPos, PatPos: PChar;
  MsgPos2, PatPos2: PChar;
  i: Integer;
begin
  Result:=false;
  {$IFDEF VerboseFPCTranslate}
  debugln(['FPCMsgFits Msg="',Msg,'" Pattern="',Pattern,'"']);
  {$ENDIF}
  if (Msg='') or (Pattern='') then exit;
  MsgPos:=PChar(Msg);
  PatPos:=PChar(Pattern);
  // skip the characters of Msg copied from Pattern
  while not IsFPCMsgEndOrVar(PatPos) do begin
    if (MsgPos^<>PatPos^) then begin
      // Pattern does not fit
      {$IFDEF VerboseFPCTranslate}
      debugln(['FPCMsgFits skipping start of Src and SrcPattern failed']);
      {$ENDIF}
      exit;
    end;
    inc(MsgPos);
    inc(PatPos)
  end;
  {$IFDEF VerboseFPCTranslate}
  debugln(['FPCMsgFits skipped start: SrcPos="',SrcPos,'" SrcPatPos="',SrcPatPos,'"']);
  {$ENDIF}
  if VarStarts<>nil then begin
    FillByte(VarStarts^,SizeOf(PChar)*10,0);
    FillByte(VarEnds^,SizeOf(PChar)*10,0);
  end;
  // find the parameters in Msg and store their boundaries in VarStarts, VarEnds
  while (PatPos^<>#0) do begin
    // read variable number
    inc(PatPos);
    i:=ord(PatPos^)-ord('0');
    inc(PatPos);
    if (VarEnds<>nil) and (VarEnds[i]=nil) then begin
      VarStarts[i]:=MsgPos;
      VarEnds[i]:=nil;
    end;
    // find the end of the parameter in Msg
    // example:  Pattern='$1 found' Msg='Ha found found'
    repeat
      if MsgPos^=PatPos^ then begin
        {$IFDEF VerboseFPCTranslate}
        debugln(['FPCMsgFits candidate for param ',i,' end: SrcPos="',SrcPos,'" SrcPatPos="',SrcPatPos,'"']);
        {$ENDIF}
        MsgPos2:=MsgPos;
        PatPos2:=PatPos;
        while (MsgPos2^=PatPos2^) and not IsFPCMsgEndOrVar(PatPos2) do begin
          inc(MsgPos2);
          inc(PatPos2);
        end;
        if IsFPCMsgEndOrVar(PatPos2) then begin
          {$IFDEF VerboseFPCTranslate}
          debugln(['FPCMsgFits param ',i,' end found: SrcPos2="',SrcPos2,'" SrcPatPos2="',SrcPatPos2,'"']);
          {$ENDIF}
          if (VarEnds<>nil) and (VarEnds[i]=nil) then
            VarEnds[i]:=MsgPos;
          MsgPos:=MsgPos2;
          PatPos:=PatPos2;
          break;
        end;
        {$IFDEF VerboseFPCTranslate}
        debugln(['FPCMsgFits searching further...']);
        {$ENDIF}
      end else if MsgPos^=#0 then begin
        if IsFPCMsgEndOrVar(PatPos) then begin
          // empty parameter at end
          if (VarEnds<>nil) and (VarEnds[i]=nil) then
            VarEnds[i]:=MsgPos;
          break;
        end else begin
          // Pattern does not fit Msg
          {$IFDEF VerboseFPCTranslate}
          debugln(['FPCMsgFits finding end of parameter ',i,' failed']);
          {$ENDIF}
          exit;
        end;
      end;
      inc(MsgPos);
    until false;
  end;
  Result:=true;
end;

function GetFPCMsgValue1(const Src, Pattern: string; out Value1: string
  ): boolean;
{ Pattern: 'Compiling $1'
  Src:     'Compiling fcllaz.pas'
  Value1:  'fcllaz.pas'
}
var
  p: SizeInt;
begin
  p:=Pos('$1',Pattern);
  if p<1 then begin
    Result:=false;
    Value1:='';
  end else begin
    Value1:=copy(Src,p,length(Src)-length(Pattern)+2);
    Result:=true;
  end;
end;

function GetFPCMsgValues(Src, Pattern: string; out Value1, Value2: string
  ): boolean;
{ Pattern: 'Unit $1 was not found but $2 exists'
  Src:     'Unit dialogprocs was not found but dialogpr exists'
  Value1:  'dialogprocs'
  Value1:  'dialogpr'
  Not supported: '$1$2'
}
var
  p1: SizeInt;
  LastPattern: String;
  p2: SizeInt;
  MiddlePattern: String;
  SrcP1Behind: Integer;
  SrcP2: Integer;
begin
  Result:=false;
  Value1:='';
  Value2:='';
  p1:=Pos('$1',Pattern);
  if p1<1 then exit;
  p2:=Pos('$2',Pattern);
  if p2<=p1+2 then exit;
  if LeftStr(Pattern,p1-1)<>LeftStr(Src,p1-1) then exit;
  LastPattern:=RightStr(Pattern,length(Pattern)-p2-1);
  if RightStr(Src,length(LastPattern))<>LastPattern then exit;
  MiddlePattern:=copy(Pattern,p1+2,p2-p1-2);
  SrcP1Behind:=PosEx(MiddlePattern,Src,p1+2);
  if SrcP1Behind<1 then exit;
  Value1:=copy(Src,p1,SrcP1Behind-p1);
  SrcP2:=SrcP1Behind+length(MiddlePattern);
  Value2:=copy(Src,SrcP2,length(Src)-SrcP2-length(LastPattern)+1);
  Result:=true;
end;

function IsFileInIDESrcDir(Filename: string): boolean;
var
  LazDir: String;
begin
  Filename:=TrimFilename(Filename);
  if not FilenameIsAbsolute(Filename) then exit(false);
  LazDir:=AppendPathDelim(EnvironmentOptions.GetParsedLazarusDirectory);
  Result:=FileIsInPath(Filename,LazDir+'ide')
       or FileIsInPath(Filename,LazDir+'debugger')
       or FileIsInPath(Filename,LazDir+'packager')
       or FileIsInPath(Filename,LazDir+'converter')
       or FileIsInPath(Filename,LazDir+'designer');
end;

procedure RegisterFPCParser;
begin
  ExternalToolList.RegisterParser(TIDEFPCParser);
end;

{ TPatternToMsgIDs }

function TPatternToMsgIDs.IndexOf(Pattern: PChar; Insert: boolean): integer;
var
  l: Integer;
  r: Integer;
  m: Integer;
  ItemP: PChar;
  FindP: PChar;
  cmp: Integer;
begin
  Result:=-1;
  l:=0;
  r:=length(fItems)-1;
  cmp:=0;
  m:=0;
  while (l<=r) do begin
    m:=(l+r) div 2;
    ItemP:=PChar(fItems[m].Pattern);
    FindP:=Pattern;
    while (ItemP^=FindP^) do begin
      if ItemP^=#0 then
        exit(m); // exact match
      inc(ItemP);
      inc(FindP);
    end;
    if ItemP^ in [#0,'$'] then begin
      // Pattern longer than Item
      if not Insert then begin
        if (Result<0) or (length(fItems[m].Pattern)>length(fItems[Result].Pattern))
        then
          Result:=m;
      end;
    end;
    cmp:=ord(ItemP^)-ord(FindP^);
    if cmp<0 then
      l:=m+1
    else
      r:=m-1;
  end;
  if Insert then begin
    if cmp<0 then
      Result:=m+1
    else
      Result:=m;
  end;
end;

constructor TPatternToMsgIDs.Create;
begin

end;

destructor TPatternToMsgIDs.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TPatternToMsgIDs.Clear;
var
  i: Integer;
begin
  for i:=0 to length(fItems)-1 do
    fItems[i].Free;
  SetLength(fItems,0);
end;

procedure TPatternToMsgIDs.Add(Pattern: string; MsgID: integer);

  procedure RaiseInvalidMsgID;
  var
    s: String;
  begin
    s:='invalid MsgID: '+IntToStr(MsgID);
    raise Exception.Create(s);
  end;

var
  i: Integer;
  Item: TPatternToMsgID;
  Cnt: Integer;
begin
  if MsgID=0 then
    RaiseInvalidMsgID;
  Pattern:=Trim(Pattern);
  if (Pattern='') or (Pattern[1]='$') then exit;
  i:=IndexOf(PChar(Pattern),true);
  Cnt:=length(fItems);
  SetLength(fItems,Cnt+1);
  if Cnt-i>0 then
    Move(fItems[i],fItems[i+1],SizeOf(TPatternToMsgID)*(Cnt-i));
  Item:=TPatternToMsgID.Create;
  fItems[i]:=Item;
  Item.Pattern:=Pattern;
  Item.MsgID:=MsgID;
end;

procedure TPatternToMsgIDs.AddLines(const Lines: string; MsgID: integer);
var
  StartPos: PChar;
  p: PChar;
begin
  p:=PChar(Lines);
  while p^<>#0 do begin
    StartPos:=p;
    while not (p^ in [#0,#10,#13]) do inc(p);
    if p>StartPos then begin
      Add(copy(Lines,StartPos-PChar(Lines)+1,p-StartPos),MsgID);
    end;
    while p^ in [#10,#13] do inc(p);
  end;
end;

function TPatternToMsgIDs.LineToMsgID(p: PChar): integer;
var
  i: Integer;
begin
  while p^ in [' ',#9,#10,#13] do inc(p);
  i:=IndexOf(p,false);
  if i<0 then
    Result:=0
  else
    Result:=fItems[i].MsgID;
end;

procedure TPatternToMsgIDs.WriteDebugReport;
var
  i: Integer;
begin
  debugln(['TLineStartToMsgIDs.WriteDebugReport Count=',length(fItems)]);
  for i:=0 to Length(fItems)-1 do begin
    debugln(['  ID=',fItems[i].MsgID,'="',fItems[i].Pattern,'"']);
  end;
  ConsistencyCheck;
end;

procedure TPatternToMsgIDs.ConsistencyCheck;

  procedure E(Msg: string);
  begin
    raise Exception.Create(Msg);
  end;

var
  i: Integer;
  Item: TPatternToMsgID;
begin
  for i:=0 to Length(fItems)-1 do begin
    Item:=fItems[i];
    if Item.MsgID<=0 then
      E('Item.MsgID<=0');
    if Item.Pattern='' then
      E('Item.Pattern empty');
    if IndexOf(PChar(Item.Pattern),false)<>i then
      E('IndexOf '+dbgs(i)+' "'+Item.Pattern+'" IndexOf='+dbgs(IndexOf(PChar(Item.Pattern),false)));
  end;
end;

{ TFPCMsgFilePool }

procedure TFPCMsgFilePool.Log(Msg: string; AThread: TThread);
begin
  EnterCriticalsection;
  try
    fPendingLog.Add(Msg);
  finally
    LeaveCriticalSection;
  end;
  if AThread<>nil then
    LogSync
  else
    TThread.Synchronize(AThread,@LogSync);
end;

procedure TFPCMsgFilePool.LogSync;
begin
  EnterCriticalsection;
  try
    dbgout(fPendingLog.Text);
  finally
    LeaveCriticalSection;
  end;
end;

procedure TFPCMsgFilePool.SetDefaultEnglishFile(AValue: string);
begin
  if FDefaultEnglishFile=AValue then Exit;
  FDefaultEnglishFile:=AValue;
  fMsgFileStamp:=-1;
end;

procedure TFPCMsgFilePool.SetDefaultTranslationFile(AValue: string);
begin
  if FDefaultTranslationFile=AValue then Exit;
  FDefaultTranslationFile:=AValue;
  fMsgFileStamp:=-1;
end;

constructor TFPCMsgFilePool.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  InitCriticalSection(fCritSec);
  FFiles:=TFPList.Create;
  fPendingLog:=TStringList.Create;
  fMsgFileStamp:=-1;
end;

destructor TFPCMsgFilePool.Destroy;
var
  i: Integer;
  Item: TFPCMsgFilePoolItem;
begin
  EnterCriticalsection;
  try
    // free unused files
    for i:=FFiles.Count-1 downto 0 do begin
      Item:=TFPCMsgFilePoolItem(FFiles[i]);
      if Item.fUseCount=0 then begin
        Item.Free;
        FFiles.Delete(i);
      end else begin
        debugln(['TFPCMsgFilePool.Destroy file still used: ',Item.Filename]);
      end;
    end;
    if FFiles.Count>0 then
      raise Exception.Create('TFPCMsgFilePool.Destroy some files are still used');
    FreeAndNil(FFiles);
    if FPCMsgFilePool=Self then
      FPCMsgFilePool:=nil;
    inherited Destroy;
    FreeAndNil(fPendingLog);
  finally
    LeaveCriticalSection;
  end;
  DoneCriticalsection(fCritSec);
end;

function TFPCMsgFilePool.LoadCurrentEnglishFile(UpdateFromDisk: boolean;
  AThread: TThread): TFPCMsgFilePoolItem;
var
  anEnglishFile: string;
  aTranslationFile: string;
begin
  Result:=nil;
  GetMsgFileNames(EnvironmentOptions.GetParsedCompilerFilename,'','',
    anEnglishFile,aTranslationFile);
  if not FilenameIsAbsolute(anEnglishFile) then exit;
  Result:=LoadFile(anEnglishFile,UpdateFromDisk,AThread);
end;

function TFPCMsgFilePool.LoadFile(aFilename: string; UpdateFromDisk: boolean;
  AThread: TThread): TFPCMsgFilePoolItem;
var
  IsMainThread: Boolean;

  procedure ResultOutdated;
  begin
    // cached file needs update
    if Result.fUseCount=0 then begin
      FFiles.Remove(Result);
      Result.Free;
    end;
    Result:=nil;
  end;

  function FileExists: boolean;
  begin
    if IsMainThread then
      Result:=FileExistsCached(aFilename)
    else
      Result:=FileExistsUTF8(aFilename);
  end;

  function FileAge: longint;
  begin
    if IsMainThread then
      Result:=FileAgeCached(aFilename)
    else
      Result:=FileAgeUTF8(aFilename);
  end;

var
  Item: TFPCMsgFilePoolItem;
  i: Integer;
  NewItem: TFPCMsgFilePoolItem;
  FileTxt: string;
  ms: TMemoryStream;
  Encoding: String;
begin
  Result:=nil;
  if aFilename='' then exit;
  aFilename:=TrimAndExpandFilename(aFilename);
  //Log('TFPCMsgFilePool.LoadFile '+aFilename,aThread);

  IsMainThread:=GetThreadID=MainThreadID;
  if UpdateFromDisk then begin
    if not FileExists then begin
      Log('TFPCMsgFilePool.LoadFile file not found: '+aFilename,AThread);
      exit;
    end;
  end;
  NewItem:=nil;
  ms:=nil;
  EnterCriticalsection;
  try
    // search the newest version in cache
    for i:=FFiles.Count-1 downto 0 do begin
      Item:=TFPCMsgFilePoolItem(FFiles[i]);
      if CompareFilenames(Item.Filename,aFilename)<>0 then continue;
      Result:=Item;
      break;
    end;
    if UpdateFromDisk then begin
      if (Result<>nil)
      and (FileAge<>Result.LoadedFileAge) then
        ResultOutdated;
    end else if Result=nil then begin
      // not yet loaded, not yet checked if file exists -> check now
      if not FileExists then
        exit;
    end;

    if Result<>nil then begin
      // share
      inc(Result.fUseCount);
    end else begin
      // load for the first time
      NewItem:=TFPCMsgFilePoolItem.Create(Self,aFilename);
      //Log('TFPCMsgFilePool.LoadFile '+dbgs(NewItem.FMsgFile<>nil)+' '+aFilename,aThread);
      if Assigned(OnLoadFile) then begin
        OnLoadFile(aFilename,FileTxt);
      end else begin
        ms:=TMemoryStream.Create;
        ms.LoadFromFile(aFilename);
        SetLength(FileTxt,ms.Size);
        ms.Position:=0;
        if FileTxt<>'' then
          ms.Read(FileTxt[1],length(FileTxt));
      end;
      // convert encoding
      Encoding:=GetDefaultFPCErrorMsgFileEncoding(aFilename);
      FileTxt:=ConvertEncoding(FileTxt,Encoding,EncodingUTF8);
      // parse
      NewItem.FMsgFile.LoadFromText(FileTxt);
      NewItem.FLoadedFileAge:=FileAge;
      // load successful
      Result:=NewItem;
      NewItem:=nil;
      FFiles.Add(Result);
      inc(Result.fUseCount);
      //log('TFPCMsgFilePool.LoadFile '+Result.Filename+' '+dbgs(Result.fUseCount),aThread);
    end;
  finally
    ms.Free;
    FreeAndNil(NewItem);
    LeaveCriticalSection;
  end;
end;

procedure TFPCMsgFilePool.UnloadFile(var aFile: TFPCMsgFilePoolItem);
var
  i: Integer;
  Item: TFPCMsgFilePoolItem;
  Keep: Boolean;
begin
  EnterCriticalsection;
  try
    if aFile.fUseCount<=0 then
      raise Exception.Create('TFPCMsgFilePool.UnloadFile already freed');
    if FFiles.IndexOf(aFile)<0 then
      raise Exception.Create('TFPCMsgFilePool.UnloadFile unknown, maybe already freed');
    dec(aFile.fUseCount);
    //log('TFPCMsgFilePool.UnloadFile '+aFile.Filename+' UseCount='+dbgs(aFile.fUseCount),aThread);
    if aFile.fUseCount>0 then exit;
    // not used anymore
    if not FileExistsUTF8(aFile.Filename) then begin
      Keep:=false;
    end else begin
      // file still exist on disk
      // => check if it is the newest version
      Keep:=true;
      for i:=FFiles.Count-1 downto 0 do begin
        Item:=TFPCMsgFilePoolItem(FFiles[i]);
        if Item=aFile then break;
        if CompareFilenames(Item.Filename,aFile.Filename)<>0 then continue;
        // there is already a newer version
        Keep:=false;
        break;
      end;
    end;
    if Keep then begin
      // this file is the newest version => keep it in cache
    end else begin
      //log('TFPCMsgFilePool.UnloadFile free: '+aFile.Filename,aThread);
      FFiles.Remove(aFile);
      aFile.Free;
    end;
  finally
    aFile:=nil;
    LeaveCriticalSection;
  end;
end;

procedure TFPCMsgFilePool.EnterCriticalsection;
begin
  System.EnterCriticalsection(fCritSec);
end;

procedure TFPCMsgFilePool.LeaveCriticalSection;
begin
  System.LeaveCriticalsection(fCritSec);
end;

procedure TFPCMsgFilePool.GetMsgFileNames(CompilerFilename, TargetOS,
  TargetCPU: string; out anEnglishFile, aTranslationFile: string);
var
  FPCVer: String;
  FPCSrcDir: String;
  aFilename: String;
  ErrMsg: string;
begin
  if fMsgFileStamp<>CompilerParseStamp then begin
    fCurrentEnglishFile:=DefaultEnglishFile;
    fCurrentTranslationFile:=DefaulTranslationFile;
    // English msg file
    // => use fpcsrcdir/compiler/msg/errore.msg
    // the fpcsrcdir might depend on the FPC version
    if IsFPCExecutable(CompilerFilename,ErrMsg) then
      FPCVer:=CodeToolBoss.FPCDefinesCache.GetFPCVersion(CompilerFilename,TargetOS,TargetCPU,false)
    else
      FPCVer:='';
    FPCSrcDir:=EnvironmentOptions.GetParsedFPCSourceDirectory(FPCVer);
    if FilenameIsAbsolute(FPCSrcDir) then begin
      // FPCSrcDir exists => use the errore.msg
      aFilename:=AppendPathDelim(FPCSrcDir)+SetDirSeparators('compiler/msg/errore.msg');
      if FileExistsCached(aFilename) then
        fCurrentEnglishFile:=aFilename;
    end;
    if not FileExistsCached(fCurrentEnglishFile) then begin
      // as fallback use the copy in the Codetools directory
      aFilename:=EnvironmentOptions.GetParsedLazarusDirectory;
      if FilenameIsAbsolute(aFilename) then begin
        aFilename:=AppendPathDelim(aFilename)+SetDirSeparators('components/codetools/fpc.errore.msg');
        if FileExistsCached(aFilename) then
          fCurrentEnglishFile:=aFilename;
      end;
    end;
    // translation msg file
    aFilename:=EnvironmentOptions.GetParsedCompilerMessagesFilename;
    if FilenameIsAbsolute(aFilename) and FileExistsCached(aFilename)
    and (CompareFilenames(aFilename,fCurrentEnglishFile)<>0) then
      fCurrentTranslationFile:=aFilename;
    fMsgFileStamp:=CompilerParseStamp;
  end;
  anEnglishFile:=fCurrentEnglishFile;
  aTranslationFile:=fCurrentTranslationFile;
end;

{ TFPCMsgFilePoolItem }

constructor TFPCMsgFilePoolItem.Create(aPool: TFPCMsgFilePool;
  const aFilename: string);
begin
  inherited Create;
  FPool:=aPool;
  FFilename:=aFilename;
  FMsgFile:=TFPCMsgFile.Create;
end;

destructor TFPCMsgFilePoolItem.Destroy;
begin
  FreeAndNil(FMsgFile);
  FFilename:='';
  inherited Destroy;
end;

function TFPCMsgFilePoolItem.GetMsg(ID: integer): TFPCMsgItem;
begin
  Result:=FMsgFile.FindWithID(ID);
end;

{ TIDEFPCParser }

destructor TIDEFPCParser.Destroy;
begin
  FreeAndNil(FFilesToIgnoreUnitNotUsed);
  FreeAndNil(fFileExists);
  FreeAndNil(fLastSource);
  if TranslationFile<>nil then
    FPCMsgFilePool.UnloadFile(TranslationFile);
  if MsgFile<>nil then
    FPCMsgFilePool.UnloadFile(MsgFile);
  FreeAndNil(DirectoryStack);
  FreeAndNil(fLineToMsgID);
  inherited Destroy;
end;

procedure TIDEFPCParser.Init;

  procedure LoadMsgFile(aFilename: string; var List: TFPCMsgFilePoolItem);
  begin
    //debugln(['TFPCParser.Init load Msg filename=',aFilename]);
    if aFilename='' then
      debugln(['WARNING: TFPCParser.Init missing msg file'])
    else if (aFilename<>'') and (List=nil) then begin
      try
        List:=FPCMsgFilePool.LoadFile(aFilename,true,nil);
        {$IFDEF VerboseExtToolThread}
        debugln(['LoadMsgFile successfully read ',aFilename]);
        {$ENDIF}
      except
        on E: Exception do begin
          debugln(['WARNING: TFPCParser.Init failed to load file '+aFilename+': '+E.Message]);
        end;
      end;
    end;
  end;

var
  i: Integer;
  Param: String;
  p: PChar;
  aTargetOS: String;
  aTargetCPU: String;
begin
  inherited Init;

  if FPCMsgFilePool<>nil then begin
    aTargetOS:='';
    aTargetCPU:='';
    for i:=0 to Tool.Process.Parameters.Count-1 do begin
      Param:=Tool.Process.Parameters[i];
      if Param='' then continue;
      p:=PChar(Param);
      if p^<>'-' then continue;
      if p[1]='T' then
        aTargetOS:=copy(Param,3,255)
      else if p[1]='P' then
        aTargetCPU:=copy(Param,3,255);
    end;
    FPCMsgFilePool.GetMsgFileNames(Tool.Process.Executable,aTargetOS,aTargetCPU,
      MsgFilename,TranslationFilename);
  end;

  LoadMsgFile(MsgFilename,MsgFile);
  if TranslationFilename<>'' then
    LoadMsgFile(TranslationFilename,TranslationFile);

  // get include search path
  fIncludePathValidForWorkerDir:=Tool.WorkerDirectory;
  fIncludePath:=CodeToolBoss.GetIncludePathForDirectory(
                           ChompPathDelim(fIncludePathValidForWorkerDir));
end;

procedure TIDEFPCParser.InitReading;

  procedure AddPatternItem(MsgID: integer);
  var
    Item: TFPCMsgItem;
  begin
    Item:=MsgFile.GetMsg(MsgID);
    if Item<>nil then
      fLineToMsgID.AddLines(Item.Pattern,Item.ID);
  end;

begin
  inherited InitReading;

  fLineToMsgID.Clear;
  AddPatternItem(FPCMsgIDLogo);
  AddPatternItem(FPCMsgIDLinking);
  AddPatternItem(FPCMsgIDCallingResourceCompiler);
  //fLineToMsgID.WriteDebugReport;

  fLastWorkerImprovedMessage[false]:=-1;
  fLastWorkerImprovedMessage[true]:=-1;

  FreeAndNil(DirectoryStack);
end;

procedure TIDEFPCParser.Done;
begin
  FreeAndNil(fLastSource);
  inherited Done;
end;

function TIDEFPCParser.CheckForCompilingState(p: PChar): boolean;
const
  FPCMsgIDCompiling = 3104;
var
  AFilename: string;
  MsgLine: TMessageLine;
  OldP: PChar;
begin
  OldP:=p;
  // for example 'Compiling ./subdir/unit1.pas'
  if fMsgID=0 then begin
    if not ReadString(p,'Compiling ') then exit(false);
    fMsgID:=FPCMsgIDCompiling;
    Result:=true;
  end else if fMsgID=FPCMsgIDCompiling then begin
    Result:=true;
    if not ReadString(p,'Compiling ') then exit;
  end else begin
    exit(false);
  end;
  // add path to history
  if (p^='.') and (p[1]=PathDelim) then
    inc(p,2); // skip ./
  AFilename:=ExtractFilePath(TrimFilename(p));
  if AFilename<>'' then begin
    if (not FilenameIsAbsolute(AFilename)) and (Tool.WorkerDirectory<>'') then
      AFilename:=TrimFilename(AppendPathDelim(Tool.WorkerDirectory)+AFilename);
    if DirectoryStack=nil then DirectoryStack:=TStringList.Create;
    if (DirectoryStack.Count=0)
    or (DirectoryStack[DirectoryStack.Count-1]<>AFilename) then
      DirectoryStack.Add(AFilename);
  end;
  MsgLine:=CreateMsgLine;
  MsgLine.Urgency:=mluProgress;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Filename:=AFilename;
  MsgLine.Msg:=OldP;
  AddMsgLine(MsgLine);
  Result:=true;
end;

function TIDEFPCParser.CheckForAssemblingState(p: PChar): boolean;
var
  MsgLine: TMessageLine;
  OldP: PChar;
begin
  Result:=fMsgID=9001;
  if (fMsgID>0) and not Result then exit;
  OldP:=p;
  if (not Result) and (not CompStr('Assembling ',p)) then exit;
  MsgLine:=CreateMsgLine;
  MsgLine.Urgency:=mluProgress;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=mluProgress;
  MsgLine.Msg:=OldP;
  AddMsgLine(MsgLine);
  Result:=true;
end;

function TIDEFPCParser.CheckForGeneralMessage(p: PChar): boolean;
{ check for
  Fatal: message
  Hint: (11030) Start of reading config file /etc/fpc.cfg
  Error: /usr/bin/ppc386 returned an error exitcode
}
const
  FPCMsgIDCompilationAborted = 1018;
  FrontEndFPCExitCodeError = 'returned an error exitcode';
var
  MsgLine: TMessageLine;
  MsgType: TMessageLineUrgency;
  p2: PChar;
  i: Integer;
  TranslatedItem: TFPCMsgItem;
  MsgItem: TFPCMsgItem;
  TranslatedMsg: String;

  procedure CheckFinalNote;
  // check if there was already an error message
  // if yes, then downgrade this message to a mluVerbose
  var
    u: TMessageLineUrgency;
  begin
    for u:=mluError to high(TMessageLineUrgency) do
      if Tool.WorkerMessages.UrgencyCounts[u]>0 then
      begin
        MsgType:=mluVerbose;
        exit;
      end;
  end;

begin
  Result:=false;
  MsgType:=mluNone;
  if ReadString(p,'Fatal: ') then begin
    MsgType:=mluFatal;
    // check for "Fatal: compilation aborted"
    if fMsgItemCompilationAborted=nil then begin
      fMsgItemCompilationAborted:=MsgFile.GetMsg(FPCMsgIDCompilationAborted);
      if fMsgItemCompilationAborted=nil then
        fMsgItemCompilationAborted:=fMissingFPCMsgItem;
    end;
    p2:=p;
    if (fMsgItemCompilationAborted<>fMissingFPCMsgItem)
    and ReadString(p2,fMsgItemCompilationAborted.Pattern) then
      CheckFinalNote;
  end
  else if ReadString(p,'Panic') then
    MsgType:=mluPanic
  else if ReadString(p,'Error: ') then begin
    // check for fpc frontend message "Error: /usr/bin/ppc386 returned an error exitcode"
    TranslatedMsg:=p;
    MsgType:=mluError;
    if Pos(FrontEndFPCExitCodeError,TranslatedMsg)>0 then begin
      fMsgID:=FPCMsgIDCompilationAborted;
      CheckFinalNote;
    end;
  end
  else if ReadString(p,'Warn: ') then
    MsgType:=mluWarning
  else if ReadString(p,'Note: ') then
    MsgType:=mluNote
  else if ReadString(p,'Hint: ') then
    MsgType:=mluHint
  else if ReadString(p,'Debug: ') then
    MsgType:=mluDebug
  else begin
    exit;
  end;
  if MsgType=mluNone then exit;

  Result:=true;
  while p^ in [' ',#9] do inc(p);
  TranslatedMsg:='';
  if (p^='(') and (p[1] in ['0'..'9']) then begin
    p2:=p;
    inc(p2);
    i:=0;
    while (p2^ in ['0'..'9']) and (i<1000000) do begin
      i:=i*10+ord(p2^)-ord('0');
      inc(p2);
    end;
    if p2^=')' then begin
      fMsgID:=i;
      p:=p2+1;
      while p^ in [' ',#9] do inc(p);
      //if Pos('reading',String(p))>0 then
      //  debugln(['TFPCParser.CheckForGeneralMessage ID=',fMsgID,' Msg=',p]);
      if (fMsgID>0) then begin
        TranslatedItem:=nil;
        MsgItem:=nil;
        if (MsgFile<>nil) then
          MsgItem:=MsgFile.GetMsg(fMsgID);
        if (TranslationFile<>nil) then
          TranslatedItem:=TranslationFile.GetMsg(fMsgID);
        Translate(p,MsgItem,TranslatedItem,TranslatedMsg,MsgType);
        if (TranslatedItem=nil) and (MsgItem=nil) then begin
          if ConsoleVerbosity>=0 then
            debugln(['TFPCParser.CheckForGeneralMessage msgid not found: ',fMsgID]);
        end;
      end;

    end;
  end;
  if (MsgType>=mluError) and (fMsgID=FPCMsgIDCompilationAborted) // fatal: Compilation aborted
  then begin
    CheckFinalNote;
  end;
  MsgLine:=CreateMsgLine;
  MsgLine.Urgency:=MsgType;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Msg:=p;
  MsgLine.TranslatedMsg:=TranslatedMsg;
  AddMsgLine(MsgLine);
end;

function TIDEFPCParser.CheckForLineProgress(p: PChar): boolean;
// for example:  600 206.521/231.648 Kb Used
var
  OldP: PChar;
  MsgLine: TMessageLine;
begin
  Result:=false;
  OldP:=p;
  if not ReadNumberWithThousandSep(p) then exit;
  if not ReadChar(p,' ') then exit;
  if not ReadNumberWithThousandSep(p) then exit;
  if not ReadChar(p,'/') then exit;
  if not ReadNumberWithThousandSep(p) then exit;
  if not ReadChar(p,' ') then exit;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=mluProgress;
  MsgLine.Msg:=OldP;
  AddMsgLine(MsgLine);
  Result:=true;
end;

function TIDEFPCParser.CheckForLinesCompiled(p: PChar): boolean;
var
  OldStart: PChar;
  MsgLine: TMessageLine;
begin
  Result:=fMsgID=1008;
  if (fMsgID>0) and not Result then exit;
  OldStart:=p;
  if not Result then begin
    if not ReadNumberWithThousandSep(p) then exit;
    if not ReadString(p,' lines compiled, ') then exit;
    if not ReadNumberWithThousandSep(p) then exit;
  end;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=mluProgress;
  MsgLine.Msg:=OldStart;
  AddMsgLine(MsgLine);
  Result:=true;
end;

function TIDEFPCParser.CheckForExecutableInfo(p: PChar): boolean;
{ For example:
Size of Code: 1184256 bytes
Size of initialized data: 519168 bytes
Size of uninitialized data: 83968 bytes
Stack space reserved: 262144 bytes
Stack space commited: 4096 bytes
}
var
  OldStart: PChar;
  MsgLine: TMessageLine;
begin
  Result:=(fMsgID>=9130) and (fMsgID<=9140);
  if (fMsgID>0) and not Result then exit;
  OldStart:=p;
  if (not Result) then begin
    if not (ReadString(p,'Size of Code: ') or
            ReadString(p,'Size of initialized data: ') or
            ReadString(p,'Size of uninitialized data: ') or
            ReadString(p,'Stack space reserved: ') or
            ReadString(p,'Stack space commited: ') or // message contains typo
            ReadString(p,'Stack space committed: ')) then exit;
    if not ReadNumberWithThousandSep(p) then exit;
    if not ReadString(p,' bytes') then exit;
  end;
  Result:=true;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=mluProgress;
  MsgLine.Msg:=OldStart;
  AddMsgLine(MsgLine);
end;

function TIDEFPCParser.CheckForRecompilingChecksumChangedMessages(p: PChar
  ): boolean;
// example: Recompiling GtkInt, checksum changed for gdk2x
var
  OldStart: PChar;
  MsgLine: TMessageLine;
begin
  Result:=fMsgID=10028;
  if (fMsgID>0) and not Result then exit;
  OldStart:=p;
  if not Result then begin
    if not CompStr('Recompiling ',p) then exit;
    while not (p^ in [',',#0]) do inc(p);
    if not CompStr(', checksum changed for ',p) then exit;
    Result:=true;
  end;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool :=SubToolFPC;
  MsgLine.Urgency:=mluVerbose;
  MsgLine.Msg:=OldStart;
  AddMsgLine(MsgLine);
end;

function TIDEFPCParser.CheckForWindresErrors(p: PChar): boolean;
// example: ...\windres.exe: warning: ...
var
  MsgLine: TMessageLine;
  WPos: PChar;
begin
  Result := false;
  WPos:=FindSubStrI('windres',p);
  if WPos=nil then exit;
  Result:=true;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:='windres';
  MsgLine.Urgency:=mluWarning;
  p := wPos + 7;
  if CompStr('.exe', p) then
    inc(p, 4);
  MsgLine.Msg:='windres' + p;
  AddMsgLine(MsgLine);
end;

function TIDEFPCParser.CheckForInfos(p: PChar): boolean;
var
  MsgItem: TFPCMsgItem;
  MsgLine: TMessageLine;
  i: Integer;
  MsgType: TMessageLineUrgency;
begin
  Result:=false;
  i:=fLineToMsgID.LineToMsgID(p);
  if i=0 then exit;
  fMsgID:=i;
  if (fMsgID=FPCMsgIDLogo) and (DirectoryStack<>nil) then begin
    // a new call of the compiler (e.g. when compiling via make)
    // => clear stack
    FreeAndNil(DirectoryStack);
  end;
  MsgItem:=MsgFile.GetMsg(fMsgID);
  if MsgItem=nil then exit;
  Result:=true;
  MsgType:=FPCMsgToMsgUrgency(MsgItem);
  if MsgType=mluNone then
    MsgType:=mluVerbose;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=MsgType;
  AddMsgLine(MsgLine);
end;

function TIDEFPCParser.CreateMsgLine: TMessageLine;
begin
  Result:=inherited CreateMsgLine(fOutputIndex);
  Result.MsgID:=fMsgID;
end;

procedure TIDEFPCParser.AddLinkingMessages;
{ Add messages for all output between "Linking ..." and the
  current line "Error while linking"

For example:
  Linking /home/user/project1
  /usr/bin/ld: warning: /home/user/link.res contains output sections; did you forget -T?
  /usr/bin/ld: cannot find -la52
  project1.lpr(20,1) Error: Error while linking

  Examples for linking errors:
  linkerror.o(.text$_main+0x9):linkerror.pas: undefined reference to `NonExistingFunction'

  /path/lib/x86_64-linux/blaunit.o: In function `FORMCREATE':
  /path//blaunit.pas:45: undefined reference to `BLAUNIT_BLABLA'

  Closing script ppas.sh

  Mac OS X linker example:
  ld: framework not found Cocoas

  Multiline Mac OS X linker example:
  Undefined symbols:
    "_exterfunc", referenced from:
        _PASCALMAIN in testld.o
    "_exterfunc2", referenced from:
        _PASCALMAIN in testld.o
  ld: symbol(s) not found

  Linking project1
  Undefined symbols for architecture x86_64:
    "_GetCurrentEventButtonState", referenced from:
        _COCOAINT_TCOCOAWIDGETSET_$__GETKEYSTATE$LONGINT$$SMALLINT in cocoaint.o
  ld: symbol(s) not found for architecture x86_64
  An error occurred while linking
}
var
  i: Integer;
  MsgLine: TMessageLine;
begin
  // find message "Linking ..."
  i:=Tool.WorkerMessages.Count-1;
  while (i>=0) and (Tool.WorkerMessages[i].MsgID<>FPCMsgIDLinking) do
    dec(i);
  if i<0 then exit;
  MsgLine:=Tool.WorkerMessages[i];
  for i:=MsgLine.OutputIndex+1 to fOutputIndex-1 do begin
    MsgLine:=inherited CreateMsgLine(i);
    MsgLine.MsgID:=0;
    MsgLine.SubTool:=SubToolFPCLinker;
    MsgLine.Urgency:=mluImportant;
    AddMsgLine(MsgLine);
  end;
end;

procedure TIDEFPCParser.AddResourceMessages;
{  Add messages for all output between "Calling resource compiler " and the
  current line "Error while compiling resources"

For example:
  Calling resource compiler "/usr/bin/fpcres" with "-o /home/user/project1.or -a x86_64 -of elf -v "@/home/user/project1.reslst"" as command line
  Debug: parsing command line parameters
  ...
  Error: Error while compiling resources
}
var
  i: Integer;
  MsgLine: TMessageLine;
begin
  // find message "Linking ..."
  i:=Tool.WorkerMessages.Count-1;
  while (i>=0) and (Tool.WorkerMessages[i].MsgID<>FPCMsgIDCallingResourceCompiler) do
    dec(i);
  if i<0 then exit;
  MsgLine:=Tool.WorkerMessages[i];
  for i:=MsgLine.OutputIndex+1 to fOutputIndex-1 do begin
    MsgLine:=inherited CreateMsgLine(i);
    MsgLine.MsgID:=0;
    MsgLine.SubTool:=SubToolFPCRes;
    MsgLine.Urgency:=mluHint;
    AddMsgLine(MsgLine);
  end;
end;

function TIDEFPCParser.IsMsgID(MsgLine: TMessageLine; MsgID: integer;
  var Item: TFPCMsgItem): boolean;
begin
  if MsgLine.MsgID=MsgID then exit(true);
  Result:=false;
  if MsgLine.MsgID<>0 then exit;
  if MsgLine.SubTool<>SubToolFPC then exit;
  if Item=nil then begin
    Item:=MsgFile.GetMsg(MsgID);
    if Item=nil then
      Item:=fMissingFPCMsgItem;
  end;
  if Item=fMissingFPCMsgItem then exit;
  if Item.PatternFits(MsgLine.Msg)<0 then exit;
  MsgLine.MsgID:=MsgID;
  Result:=true;
end;

procedure TIDEFPCParser.ImproveMsgHiddenByIDEDirective(const SourceOK: Boolean;
  var MsgLine: TMessageLine);
var
  p: PChar;
  X: Integer;
  Y: Integer;
begin
  // check for {%H-}
  if SourceOK and (not (mlfHiddenByIDEDirectiveValid in MsgLine.Flags)) then
  begin
    X:=MsgLine.Column;
    Y:=MsgLine.Line;
    if (y<=fLastSource.LineCount) and (x-1<=fLastSource.GetLineLength(y-1))
    then begin
      p:=PChar(fLastSource.Source)+fLastSource.GetLineStart(y-1)+x-2;
      //debugln(['TFPCParser.ImproveMessages ',aFilename,' ',Y,',',X,' ',copy(fLastSource.GetLine(y-1),1,x-1),'|',copy(fLastSource.GetLine(y-1),x,100),' p=',p[0],p[1],p[2]]);
      if ((p^='{') and (p[1]='%') and (p[2]='H') and (p[3]='-'))
      or ((x>5) and (p[-5]='{') and (p[-4]='%') and (p[-3]='H') and (p[-2]='-')
        and (p[-1]='}'))
      then begin
        //debugln(['TFPCParser.ImproveMessages HIDDEN ',aFilename,' ',Y,',',X,' ',MsgLine.Msg]);
        MsgLine.Flags:=MsgLine.Flags+[mlfHiddenByIDEDirective,
          mlfHiddenByIDEDirectiveValid];
      end;
    end;
    MsgLine.Flags:=MsgLine.Flags+[mlfHiddenByIDEDirectiveValid];
  end;
end;

procedure TIDEFPCParser.ImproveMsgSenderNotUsed(aSynchronized: boolean;
  MsgLine: TMessageLine);
// FPCMsgIDParameterNotUsed = 5024;  Parameter "$1" not used
begin
  if aSynchronized then exit;
  if (MsgLine.Urgency<=mluVerbose) then exit;
  // check for Sender not used
  if HideHintsSenderNotUsed
  and (MsgLine.Msg='Parameter "Sender" not used') then begin
    MsgLine.Urgency:=mluVerbose;
  end;
end;

procedure TIDEFPCParser.ImproveMsgUnitNotUsed(aSynchronized: boolean;
  MsgLine: TMessageLine);
// check for Unit not used message in main sources
// and change urgency to merely 'verbose'
const
  FPCMsgIDUnitNotUsed = 5023; // Unit "$1" not used in $2
begin
  if aSynchronized then exit;
  if (MsgLine.Urgency<=mluVerbose) then exit;
  if not IsMsgID(MsgLine,FPCMsgIDUnitNotUsed,fMsgItemUnitNotUsed) then exit;

  //debugln(['TIDEFPCParser.ImproveMsgUnitNotUsed ',aSynchronized,' ',MsgLine.Msg]);
  // unit not used
  if IndexInStringList(FilesToIgnoreUnitNotUsed,cstFilename,MsgLine.Filename)>=0 then
  begin
    MsgLine.Urgency:=mluVerbose;
  end else if HideHintsUnitNotUsedInMainSource
  and FilenameIsAbsolute(MsgLine.Filename)
  and ((CompareFileExt(MsgLine.Filename, 'lpr', false)=0)
    or FileExists(ChangeFileExt(MsgLine.Filename, '.lpk'), aSynchronized))
  then begin
    // a lpk/lpr does not use a unit => almost always not important
    MsgLine.Urgency:=mluVerbose;
  end;
end;

procedure TIDEFPCParser.ImproveMsgUnitNotFound(aSynchronized: boolean;
  MsgLine: TMessageLine);

  procedure FixSourcePos(CodeBuf: TCodeBuffer; MissingUnitname: string);
  var
    InPos: Integer;
    NamePos: Integer;
    Tool: TCodeTool;
    Caret: TCodeXYPosition;
    NewFilename: String;
  begin
    {$IFDEF VerboseQuickFixUnitNotFoundPosition}
    debugln(['TIDEFPCParser.ImproveMsgUnitNotFound File=',CodeBuf.Filename]);
    {$ENDIF}
    LazarusIDE.SaveSourceEditorChangesToCodeCache(nil);
    if not CodeToolBoss.FindUnitInAllUsesSections(CodeBuf,MissingUnitname,NamePos,InPos)
    then begin
      DebugLn('QuickFixUnitNotFoundPosition failed due to syntax errors or '+MissingUnitname+' is not used in '+CodeBuf.Filename);
      exit;
    end;
    Tool:=CodeToolBoss.CurCodeTool;
    if Tool=nil then exit;
    if not Tool.CleanPosToCaret(NamePos,Caret) then exit;
    if (Caret.X>0) and (Caret.Y>0) then begin
      //DebugLn('QuickFixUnitNotFoundPosition Line=',dbgs(Line),' Col=',dbgs(Col));
      NewFilename:=Caret.Code.Filename;
      MsgLine.SetSourcePosition(NewFilename,Caret.Y,Caret.X);
    end;
  end;

  procedure FindPPUInInstalledPkgs(MissingUnitname: string;
    var PPUFilename, PkgName: string);
  var
    i: Integer;
    Pkg: TIDEPackage;
    DirCache: TCTDirectoryCache;
    UnitOutDir: String;
  begin
    // search ppu in installed packages
    for i:=0 to PackageEditingInterface.GetPackageCount-1 do begin
      Pkg:=PackageEditingInterface.GetPackages(i);
      if Pkg.AutoInstall=pitNope then continue;
      UnitOutDir:=Pkg.LazCompilerOptions.GetUnitOutputDirectory(false);
      //debugln(['TQuickFixUnitNotFoundPosition.Execute ',Pkg.Name,' UnitOutDir=',UnitOutDir]);
      if FilenameIsAbsolute(UnitOutDir) then begin
        DirCache:=CodeToolBoss.DirectoryCachePool.GetCache(UnitOutDir,true,false);
        PPUFilename:=DirCache.FindFile(MissingUnitname+'.ppu',ctsfcLoUpCase);
        //debugln(['TQuickFixUnitNotFoundPosition.Execute ShortPPU=',PPUFilename]);
        if PPUFilename<>'' then begin
          PkgName:=Pkg.Name;
          PPUFilename:=AppendPathDelim(DirCache.Directory)+PPUFilename;
          break;
        end;
      end;
    end;
  end;

  procedure FindPackage(MissingUnitname: string; var PkgName: string;
    OnlyInstalled: boolean);
  var
    i: Integer;
    Pkg: TIDEPackage;
    j: Integer;
    PkgFile: TLazPackageFile;
  begin
    if PkgName='' then begin
      // search unit in installed packages
      for i:=0 to PackageEditingInterface.GetPackageCount-1 do begin
        Pkg:=PackageEditingInterface.GetPackages(i);
        if OnlyInstalled and (Pkg.AutoInstall=pitNope) then continue;
        if CompareTextCT(Pkg.Name,MissingUnitname)=0 then begin
          PkgName:=Pkg.Name;
          break;
        end;
        for j:=0 to Pkg.FileCount-1 do begin
          PkgFile:=Pkg.Files[j];
          if not FilenameIsPascalUnit(PkgFile.Filename) then continue;
          if CompareTextCT(ExtractFileNameOnly(PkgFile.Filename),MissingUnitname)<>0
          then continue;
          PkgName:=Pkg.Name;
          break;
        end;
      end;
    end;
  end;

var
  MissingUnitName: string;
  UsedByUnit: string;
  Filename: String;
  NewFilename: String;
  CodeBuf: TCodeBuffer;
  Owners: TFPList;
  UsedByOwner: TObject;
  PPUFilename: String;
  PkgName: String;
  OnlyInstalled: Boolean;
  s: String;
begin
  if MsgLine.Urgency<mluError then exit;
  if not IsMsgID(MsgLine,FPCMsgIDCantFindUnitUsedBy,fMsgItemCantFindUnitUsedBy)
  then // Can't find unit $1 used by $2
    exit;
  if (not aSynchronized) then begin
    NeedSynchronize:=true;
    exit;
  end;

  if not GetFPCMsgValues(MsgLine,MissingUnitName,UsedByUnit) then
    exit;
  MsgLine.Attribute[FPCMsgAttrMissingUnit]:=MissingUnitName;
  MsgLine.Attribute[FPCMsgAttrUsedByUnit]:=UsedByUnit;

  {$IFDEF VerboseQuickFixUnitNotFoundPosition}
  debugln(['TIDEFPCParser.ImproveMsgUnitNotFound Missing="',MissingUnitname,'" used by "',UsedByUnit,'"']);
  {$ENDIF}

  CodeBuf:=nil;
  Filename:=MsgLine.GetFullFilename;
  if (CompareFilenames(ExtractFileName(Filename),'staticpackages.inc')=0)
  and IsFileInIDESrcDir(Filename) then begin
    // common case: when building the IDE a package unit is missing
    // staticpackages.inc(1,1) Fatal: Can't find unit sqldblaz used by Lazarus
    // change to lazarus.pp(1,1)
    Filename:=AppendPathDelim(EnvironmentOptions.GetParsedLazarusDirectory)+'ide'+PathDelim+'lazarus.pp';
    MsgLine.SetSourcePosition(Filename,1,1);
    MsgLine.Msg:='Can''t find a valid '+MissingUnitname+'.ppu';
  end else if SysUtils.CompareText(ExtractFileNameOnly(Filename),UsedByUnit)<>0
  then begin
    // the message belongs to another unit
    NewFilename:='';
    if FilenameIsAbsolute(Filename) then
    begin
      // For example: /path/laz/main.pp(1,1) Fatal: Can't find unit lazreport used by lazarus
      // => search source 'lazarus' in directory
      NewFilename:=CodeToolBoss.DirectoryCachePool.FindUnitInDirectory(
                                     ExtractFilePath(Filename),UsedByUnit,true);
    end;
    if NewFilename='' then begin
      NewFilename:=LazarusIDE.FindUnitFile(UsedByUnit);
      if NewFilename='' then begin
        {$IFDEF VerboseQuickFixUnitNotFoundPosition}
        debugln(['TIDEFPCParser.ImproveMsgUnitNotFound unit not found: ',UsedByUnit]);
        {$ENDIF}
      end;
    end;
    if NewFilename<>'' then
      Filename:=NewFilename;
  end;

  if Filename<>'' then begin
    CodeBuf:=CodeToolBoss.LoadFile(Filename,false,false);
    if CodeBuf=nil then begin
      {$IFDEF VerboseQuickFixUnitNotFoundPosition}
      debugln(['TIDEFPCParser.ImproveMsgUnitNotFound unable to load unit: ',Filename]);
      {$ENDIF}
    end;
  end else begin
    {$IFDEF VerboseQuickFixUnitNotFoundPosition}
    debugln(['TIDEFPCParser.ImproveMsgUnitNotFound unable to locate UsedByUnit: ',UsedByUnit]);
    {$ENDIF}
  end;

  // fix line and column
  Owners:=nil;
  UsedByOwner:=nil;
  try
    if CodeBuf<>nil then begin
      FixSourcePos(CodeBuf,MissingUnitname);
      Owners:=PackageEditingInterface.GetOwnersOfUnit(CodeBuf.Filename);
      if (Owners<>nil) and (Owners.Count>0) then
        UsedByOwner:=TObject(Owners[0]);
    end;

    // if the ppu exists then improve the message
    {$IFDEF VerboseQuickFixUnitNotFoundPosition}
    debugln(['TIDEFPCParser.ImproveMsgUnitNotFound Filename=',CodeBuf.Filename]);
    {$ENDIF}
    if FilenameIsAbsolute(CodeBuf.Filename) then begin
      PPUFilename:=CodeToolBoss.DirectoryCachePool.FindCompiledUnitInCompletePath(
                        ExtractFilePath(CodeBuf.Filename),MissingUnitname);
      {$IFDEF VerboseQuickFixUnitNotFoundPosition}
      debugln(['TQuickFixUnitNotFoundPosition.Execute PPUFilename=',PPUFilename,' IsFileInIDESrcDir=',IsFileInIDESrcDir(CodeBuf.Filename)]);
      {$ENDIF}
      PkgName:='';
      OnlyInstalled:=IsFileInIDESrcDir(CodeBuf.Filename);
      if OnlyInstalled and (PPUFilename='') then begin
        FindPPUInInstalledPkgs(MissingUnitname,PPUFilename,PkgName);
      end;

      FindPackage(MissingUnitname,PkgName,OnlyInstalled);
      if PPUFilename<>'' then begin
        // there is a ppu file in the unit path
        if PPUFilename<>'' then begin
          // there is a ppu file, but the compiler didn't like it
          // => change message
          s:='Cannot find '+MissingUnitname;
          if UsedByUnit<>'' then
            s+=' used by '+UsedByUnit;
          s+=', incompatible ppu='+CreateRelativePath(PPUFilename,ExtractFilePath(CodeBuf.Filename));
          if PkgName<>'' then
            s+=', package '+PkgName;
        end else if PkgName<>'' then begin
          // ppu is missing, but the package is known
          // => change message
          s:='Can''t find ppu of unit '+MissingUnitname;
          if UsedByUnit<>'' then
            s+=' used by '+UsedByUnit;
          s+='. Maybe package '+PkgName+' needs a clean rebuild.';
        end;
      end else begin
        // there is no ppu file in the unit path
        s:='Cannot find unit '+MissingUnitname;
        if UsedByUnit<>'' then
          s+=' used by '+UsedByUnit;
        if (UsedByOwner is TIDEPackage)
        and (CompareTextCT(TIDEPackage(UsedByOwner).Name,PkgName)=0) then
        begin
          // two units of a package cannot find each other
          s+='. Check search path package '+TIDEPackage(UsedByOwner).Name+', try a clean rebuild, check implementation uses sections.';
        end else begin
          if PkgName<>'' then
            s+='. Check if package '+PkgName+' is in the dependencies';
          if UsedByOwner is TLazProject then
            s+=' of the project inspector'
          else if UsedByOwner is TIDEPackage then
            s+=' of package '+TIDEPackage(UsedByOwner).Name;
        end;
        s+='.';
      end;
      MsgLine.Msg:=s;
      {$IFDEF VerboseQuickFixUnitNotFoundPosition}
      debugln(['TIDEFPCParser.ImproveMsgUnitNotFound Msg.Msg="',MsgLine.Msg,'"']);
      {$ENDIF}
    end;
  finally
    Owners.Free;
  end;
end;

procedure TIDEFPCParser.ImproveMsgLinkerUndefinedReference(
  aSynchronized: boolean; MsgLine: TMessageLine);
{ For example:
  /path/lib/x86_64-linux/blaunit.o: In function `FORMCREATE':
  /path//blaunit.pas:45: undefined reference to `BLAUNIT_BLABLA'
}

  function CheckForFileAndLineNumber: boolean;
  var
    p: PChar;
    Msg: String;
    aFilename: String;
    LineNumber: Integer;
    i: SizeInt;
  begin
    Result:=false;
    if aSynchronized then exit;
    if MsgLine.HasSourcePosition then exit;
    Msg:=MsgLine.Msg;
    p:=PChar(Msg);
    // check for "filename:decimals: message"
    //  or unit1.o(.text+0x3a):unit1.pas:48: undefined reference to `DoesNotExist'

    // read filename
    repeat
      if p^=#0 then exit;
      inc(p);
    until (p^=':') and (p[1] in ['0'..'9']);
    aFilename:=LeftStr(Msg,p-PChar(Msg));
    // check for something):filename
    i:=Pos('):',aFilename);
    if i>0 then
      Delete(aFilename,1,i+1);
    aFilename:=TrimFilename(aFilename);

    // read line number
    inc(p);
    LineNumber:=0;
    while p^ in ['0'..'9'] do begin
      LineNumber:=LineNumber*10+ord(p^)-ord('0');
      if LineNumber>9999999 then exit;
      inc(p);
    end;
    if p^<>':' then exit;
    inc(p);
    while p^ in [' '] do inc(p);

    Result:=true;
    MsgLine.Msg:=copy(Msg,p-PChar(Msg)+1,length(Msg));
    MsgLine.Filename:=aFilename;
    MsgLine.Line:=LineNumber;
    MsgLine.Column:=1;
    MsgLine.Urgency:=mluError;
  end;

begin
  if MsgLine.SubTool<>SubToolFPCLinker then exit;

  if CheckForFileAndLineNumber then exit;
end;

procedure TIDEFPCParser.Translate(p: PChar; MsgItem, TranslatedItem: TFPCMsgItem;
  out TranslatedMsg: String; out MsgType: TMessageLineUrgency);
begin
  TranslatedMsg:='';
  MsgType:=mluNone;
  if TranslatedItem<>nil then
    MsgType:=FPCMsgToMsgUrgency(TranslatedItem);
  if (MsgType=mluNone) and (MsgItem<>nil) then
    MsgType:=FPCMsgToMsgUrgency(MsgItem);
  if TranslatedItem<>nil then begin
    if System.Pos('$',TranslatedItem.Pattern)<1 then begin
      TranslatedMsg:=TranslatedItem.Pattern;
      UTF8FixBroken(TranslatedMsg);
    end
    else if MsgItem<>nil then
      TranslatedMsg:=TranslateFPCMsg(p,MsgItem.Pattern,TranslatedItem.Pattern);
    //debugln(['TFPCParser.Translate Translation="',TranslatedMsg,'"']);
  end;
end;

constructor TIDEFPCParser.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  fMissingFPCMsgItem:=TFPCMsgItem(Pointer(1));
  fLineToMsgID:=TPatternToMsgIDs.Create;
  fFileExists:=TFilenameToPointerTree.Create(false);
  FFilesToIgnoreUnitNotUsed:=TStringList.Create;
  HideHintsSenderNotUsed:=true;
  HideHintsUnitNotUsedInMainSource:=true;
end;

function TIDEFPCParser.FileExists(const Filename: string; aSynchronized: boolean
  ): boolean;
var
  p: Pointer;
begin
  // check internal cache
  p:=fFileExists[Filename];
  if p=Pointer(Self) then
    Result:=true
  else if p=Pointer(fFileExists) then
    Result:=false
  else begin
    // check disk
    if aSynchronized then
      Result:=FileExistsCached(Filename)
    else
      Result:=FileExistsUTF8(Filename);
    // save result
    if Result then
      fFileExists[Filename]:=Pointer(Self)
    else
      fFileExists[Filename]:=Pointer(fFileExists);
  end;
end;

function TIDEFPCParser.CheckForMsgId(p: PChar): boolean;
var
  MsgItem: TFPCMsgItem;
  TranslatedItem: TFPCMsgItem;
  MsgLine: TMessageLine;
  TranslatedMsg: String;
  MsgType: TMessageLineUrgency;
  Msg: string;
begin
  Result:=false;
  if (fMsgID<1) or (MsgFile=nil) then exit;
  MsgItem:=MsgFile.GetMsg(fMsgID);
  if MsgItem=nil then exit;
  Result:=true;
  TranslatedItem:=nil;
  if (TranslationFile<>nil) then
    TranslatedItem:=TranslationFile.GetMsg(fMsgID);
  Translate(p,MsgItem,TranslatedItem,TranslatedMsg,MsgType);
  Msg:=p;
  case fMsgID of
  FPCMsgIDErrorWhileCompilingResources: // Error while compiling resources
    Msg+=' -> Compile with -vd for more details. Check for duplicates.';
  FPCMsgIDThereWereErrorsCompiling: // There were $1 errors compiling module, stopping
    MsgType:=mluVerbose;
  end;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=MsgType;
  MsgLine.Msg:=Msg;
  MsgLine.TranslatedMsg:=TranslatedMsg;
  AddMsgLine(MsgLine);
end;

function TIDEFPCParser.CheckForFileLineColMessage(p: PChar): boolean;
{ filename(line,column) Hint: message
  filename(line,column) Hint: (msgid) message
  filename(line) Hint: (msgid) message
}
var
  FileStartPos: PChar;
  FileEndPos: PChar;
  LineStartPos: PChar;
  ColStartPos: PChar;
  MsgType: TMessageLineUrgency;
  MsgLine: TMessageLine;
  p2: PChar;
  i: Integer;
  TranslatedItem: TFPCMsgItem;
  MsgItem: TFPCMsgItem;
  TranslatedMsg: String;
  aFilename: String;
  Column: Integer;
begin
  Result:=false;
  FileStartPos:=p;
  while not (p^ in ['(',#0]) do inc(p);
  if (p^<>'(') or (p=FileStartPos) or (p[-1]=' ') then exit;
  FileEndPos:=p;
  inc(p); // skip bracket
  LineStartPos:=p;
  //writeln('TFPCParser.CheckForFileLineColMessage ',FileStartPos);
  if not ReadDecimal(p) then exit;
  if p^=',' then begin
    if not ReadChar(p,',') then exit;
    ColStartPos:=p;
    if not ReadDecimal(p) then exit;
  end else
    ColStartPos:=nil;
  if not ReadChar(p,')') then exit;
  if not ReadChar(p,' ') then exit;
  MsgType:=mluNote;
  if ReadString(p,'Hint:') then begin
    MsgType:=mluHint;
  end else if ReadString(p,'Note:') then begin
    MsgType:=mluNote;
  end else if ReadString(p,'Warn:') then begin
    MsgType:=mluWarning;
  end else if ReadString(p,'Error:') then begin
    MsgType:=mluError;
  end else if ReadString(p,'Fatal:') then begin
    MsgType:=mluError;
  end else begin
    p2:=p;
    while not (p2^ in [':',#0,' ']) do inc(p2);
    if p2^=':' then begin
      // unknown type (maybe a translation?)
      p:=p2+1;
    end;
  end;
  while p^ in [' ',#9] do inc(p);
  Result:=true;
  TranslatedMsg:='';
  if (p^='(') and (p[1] in ['0'..'9']) then begin
    // (msgid)
    p2:=p;
    inc(p2);
    i:=0;
    while (p2^ in ['0'..'9']) and (i<1000000) do begin
      i:=i*10+ord(p2^)-ord('0');
      inc(p2);
    end;
    if p2^=')' then begin
      fMsgID:=i;
      p:=p2+1;
      while p^ in [' ',#9] do inc(p);
      //debugln(['TFPCParser.CheckForFileLineColMessage ID=',fMsgID,' Msg=',FileStartPos]);
      if (fMsgID>0) then begin
        TranslatedItem:=nil;
        MsgItem:=nil;
        if (TranslationFile<>nil) then
          TranslatedItem:=TranslationFile.GetMsg(fMsgID);
        if (MsgFile<>nil) then
          MsgItem:=MsgFile.GetMsg(fMsgID);
        Translate(p,MsgItem,TranslatedItem,TranslatedMsg,MsgType);
        if (TranslatedItem=nil) and (MsgItem=nil) then begin
          if ConsoleVerbosity>=0 then
            debugln(['TFPCParser.CheckForFileLineColMessage msgid not found: ',fMsgID]);
        end else if MsgType=mluNone then begin
          if ConsoleVerbosity>=0 then
            debugln(['TFPCParser.CheckForFileLineColMessage msgid has no type: ',fMsgID]);
        end;
      end;
    end;
  end;
  if ColStartPos<>nil then
    Column:=Str2Integer(ColStartPos,0)
  else
    Column:=0;

  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=MsgType;
  aFilename:=GetString(FileStartPos,FileEndPos-FileStartPos);
  MsgLine.Filename:=LongenFilename(MsgLine,aFilename);
  MsgLine.Line:=Str2Integer(LineStartPos,0);
  MsgLine.Column:=Column;
  MsgLine.Msg:=p;
  MsgLine.TranslatedMsg:=TranslatedMsg;
  //debugln(['TFPCParser.CheckForFileLineColMessage ',dbgs(MsgLine.Urgency)]);

  AddMsgLine(MsgLine);
end;

function TIDEFPCParser.CheckForLoadFromUnit(p: PChar): Boolean;
var
  OldP: PChar;
  MsgLine: TMessageLine;
begin
  Result:=fMsgID=10027;
  if (fMsgID>0) and not Result then exit;
  OldP:=p;
  if not Result then begin
    if not ReadString(p,'Load from ') then exit;
    while not (p^ in ['(',#0]) do inc(p);
    if p^<>'(' then exit;
    while not (p^ in [')',#0]) do inc(p);
    if p^<>')' then exit;
    if not ReadString(p,') unit ') then exit;
  end;
  MsgLine:=CreateMsgLine;
  MsgLine.SubTool:=SubToolFPC;
  MsgLine.Urgency:=mluProgress;
  MsgLine.Msg:=OldP;
  AddMsgLine(MsgLine);
  Result:=true;
end;

procedure TIDEFPCParser.ReadLine(Line: string; OutputIndex: integer;
  var Handled: boolean);
{ returns true, if it is a compiler message
   Examples for freepascal compiler messages:
     Compiling <filename>
     Assembling <filename>
     Fatal: <some text>
     Fatal: (message id) <some text>
     <filename>(123,45) <ErrorType>: <some text>
     <filename>(123) <ErrorType>: <some text>
     <filename>(456) <ErrorType>: <some text> in line (123)
     [0.000] (3101) Macro defined: CPUAMD64
     <filename>(12,34) <ErrorType>: (5024) <some text>
}
var
  p: PChar;
begin
  if Line='' then exit;
  p:=PChar(Line);
  fOutputIndex:=OutputIndex;
  fMsgID:=0;

  //writeln('TFPCParser.ReadLine ',Line);
  // skip time [0.000]
  if (p^='[') and (p[1] in ['0'..'9']) then begin
    inc(p,2);
    while p^ in ['0'..'9','.'] do inc(p);
    if p^<>']' then exit; // not a fpc message
    inc(p);
    while p^ in [' '] do inc(p);
  end;

  // read message ID (000)
  if (p^='(') and (p[1] in ['0'..'9']) then begin
    inc(p);
    while p^ in ['0'..'9','.'] do begin
      if fMsgID>1000000 then exit; // not a fpc message
      fMsgID:=fMsgID*10+ord(p^)-ord('0');
      inc(p);
    end;
    if p^<>')' then exit; // not a fpc message
    inc(p);
    while p^ in [' '] do inc(p);
  end;

  if p^ in [#0..#31,' '] then exit; // not a fpc message

  Handled:=true;

  // check for (msgid) message
  if CheckForMsgId(p) then exit;
  // check for 'filename(line,column) Error: message'
  if CheckForFileLineColMessage(p) then exit;
  // check for 'Compiling <filename>'
  if CheckForCompilingState(p) then exit;
  // check for 'Assembling <filename>'
  if CheckForAssemblingState(p) then exit;
  // check for 'Fatal: ', 'Panic: ', 'Error: ', ...
  if CheckForGeneralMessage(p) then exit;
  // check for '<line> <kb>/<kb>'...
  if CheckForLineProgress(p) then exit;
  // check for '<int> Lines compiled, <int>.<int> sec'
  if CheckForLinesCompiled(p) then exit;
  // check for infos (logo, Linking <Progname>)
  if CheckForInfos(p) then exit;
  // check for -vx output
  if CheckForExecutableInfo(p) then exit;
  // check for Recompiling, checksum changed
  if CheckForRecompilingChecksumChangedMessages(p) then exit;
  // check for Load from unit
  if CheckForLoadFromUnit(p) then exit;
  // check for windres errors
  if CheckForWindresErrors(p) then exit;

  {$IFDEF VerboseFPCParser}
  writeln('TFPCParser.ReadLine UNKNOWN: ',Line);
  {$ENDIF}
  Handled:=false;
end;

procedure TIDEFPCParser.AddMsgLine(MsgLine: TMessageLine);
begin
  if IsMsgID(MsgLine,FPCMsgIDErrorWhileCompilingResources,
    fMsgItemErrorWhileCompilingResources)
  then begin
    // Error while compiling resources
    AddResourceMessages;
    MsgLine.Msg:=MsgLine.Msg+' -> Compile with -vd for more details. Check for duplicates.';
  end
  else if IsMsgID(MsgLine,FPCMsgIDErrorWhileLinking,fMsgItemErrorWhileLinking) then
    AddLinkingMessages
  else if IsMsgID(MsgLine,FPCMsgIDThereWereErrorsCompiling,
    fMsgItemThereWereErrorsCompiling)
  then
    MsgLine.Urgency:=mluVerbose
  else if IsMsgID(MsgLine,FPCMsgIDIdentifierNotFound,fMsgItemIdentifierNotFound)
  then
    MsgLine.Flags:=MsgLine.Flags+[mlfLeftToken];
  inherited AddMsgLine(MsgLine);
end;

function TIDEFPCParser.LongenFilename(MsgLine: TMessageLine; aFilename: string
  ): string;
var
  ShortFilename: String;
  i: Integer;
  LastMsgLine: TMessageLine;
  LastFilename: String;
begin
  Result:=TrimFilename(aFilename);
  if FilenameIsAbsolute(Result) then exit;
  ShortFilename:=Result;
  // check last message line
  LastMsgLine:=Tool.WorkerMessages.GetLastLine;
  if (LastMsgLine<>nil) then begin
    LastFilename:=LastMsgLine.Filename;
    if FilenameIsAbsolute(LastFilename) then begin
      if (length(LastFilename)>length(ShortFilename))
      and (LastFilename[length(LastFilename)-length(ShortFilename)] in AllowDirectorySeparators)
      and (CompareFilenames(RightStr(LastFilename,length(ShortFilename)),ShortFilename)=0)
      then begin
        Result:=LastFilename;
        exit;
      end;
    end;
  end;
  // search file in the last compiling directories
  if DirectoryStack<>nil then begin
    for i:=DirectoryStack.Count-1 downto 0 do begin
      Result:=AppendPathDelim(DirectoryStack[i])+ShortFilename;
      if FileExists(Result,false) then exit;
    end;
  end;
  // search file in worker directory
  if Tool.WorkerDirectory<>'' then begin
    Result:=AppendPathDelim(Tool.WorkerDirectory)+ShortFilename;
    if FileExists(Result,false) then exit;
  end;

  // file not found
  Result:=ShortFilename;

  // save Tool.WorkerDirectory for ImproveMessage
  MsgLine.Attribute[FPCMsgAttrWorkerDirectory]:=Tool.WorkerDirectory;
end;

procedure TIDEFPCParser.ImproveMessages(aSynchronized: boolean);
var
  i: Integer;
  MsgLine: TMessageLine;
  aFilename: String;
  Y: Integer;
  X: Integer;
  Code: TCodeBuffer;
  SourceOK: Boolean;
  MsgWorkerDir: String;
begin
  //debugln(['TIDEFPCParser.ImproveMessages START ',aSynchronized,' Last=',fLastWorkerImprovedMessage[aSynchronized],' Now=',Tool.WorkerMessages.Count]);
  for i:=fLastWorkerImprovedMessage[aSynchronized]+1 to Tool.WorkerMessages.Count-1 do
  begin
    MsgLine:=Tool.WorkerMessages[i];
    Y:=MsgLine.Line;
    X:=MsgLine.Column;
    if (Y>0) and (X>0)
    and (MsgLine.SubTool=SubToolFPC) and (MsgLine.Filename<>'')
    then begin
      // try to find for short file name the full file name
      aFilename:=MsgLine.Filename;
      if (not FilenameIsAbsolute(aFilename)) then begin
        MsgWorkerDir:=MsgLine.Attribute[FPCMsgAttrWorkerDirectory];
        if fIncludePathValidForWorkerDir<>MsgWorkerDir then begin
          // fetch include path
          if aSynchronized then begin
            fIncludePathValidForWorkerDir:=MsgWorkerDir;
            fIncludePath:=CodeToolBoss.GetIncludePathForDirectory(
                                     ChompPathDelim(MsgWorkerDir));
          end else begin
            NeedSynchronize:=true;
          end;
        end;
        if fIncludePathValidForWorkerDir=MsgWorkerDir then begin
          aFilename:=SearchFileInPath(aFilename,MsgWorkerDir,fIncludePath,';',
                                 [sffSearchLoUpCase]);
          if aFilename<>'' then
            MsgLine.Filename:=aFilename;
        end;
      end;

      // get source
      SourceOK:=false;
      aFilename:=MsgLine.Filename;
      if FilenameIsAbsolute(aFilename) then begin
        if (fLastSource<>nil)
        and (CompareFilenames(aFilename,fLastSource.Filename)=0) then begin
          SourceOK:=true;
        end else begin
          if aSynchronized then begin
            // load source file
            //debugln(['TFPCParser.ImproveMessages loading ',aFilename]);
            Code:=CodeToolBoss.LoadFile(aFilename,true,false);
            if Code<>nil then begin
              if fLastSource=nil then
                fLastSource:=TCodeBuffer.Create;
              fLastSource.Filename:=aFilename;
              fLastSource.Source:=Code.Source;
              SourceOK:=true;
            end;
          end else begin
            NeedSynchronize:=true;
          end;
        end;
      end;

      if MsgLine.Urgency<mluError then
        ImproveMsgHiddenByIDEDirective(SourceOK, MsgLine);
      ImproveMsgUnitNotFound(aSynchronized, MsgLine);
      ImproveMsgUnitNotUsed(aSynchronized, MsgLine);
      ImproveMsgSenderNotUsed(aSynchronized, MsgLine);
    end else if MsgLine.SubTool=SubToolFPCLinker then begin
      ImproveMsgLinkerUndefinedReference(aSynchronized, MsgLine);
    end;
  end;
  fLastWorkerImprovedMessage[aSynchronized]:=Tool.WorkerMessages.Count-1;
end;

class function TIDEFPCParser.IsSubTool(const SubTool: string): boolean;
begin
  Result:=(CompareText(SubTool,SubToolFPC)=0)
       or (CompareText(SubTool,SubToolFPCLinker)=0)
       or (CompareText(SubTool,SubToolFPCRes)=0);
end;

class function TIDEFPCParser.DefaultSubTool: string;
begin
  Result:=SubToolFPC;
end;

class function TIDEFPCParser.GetMsgHint(SubTool: string; MsgID: integer): string;
var
  CurMsgFile: TFPCMsgFilePoolItem;
  MsgItem: TFPCMsgItem;
begin
  Result:='';
  if CompareText(SubTool,SubToolFPC)=0 then begin
    CurMsgFile:=FPCMsgFilePool.LoadCurrentEnglishFile(false,nil);
    if CurMsgFile=nil then exit;
    try
      MsgItem:=CurMsgFile.GetMsg(MsgID);
      if MsgItem=nil then exit;
      Result:=MsgItem.GetTrimmedComment(false,true);
    finally
      FPCMsgFilePool.UnloadFile(CurMsgFile);
    end;
  end;
end;

class function TIDEFPCParser.GetMsgPattern(SubTool: string; MsgID: integer
  ): string;
var
  CurMsgFile: TFPCMsgFilePoolItem;
  MsgItem: TFPCMsgItem;
begin
  Result:='';
  if CompareText(SubTool,SubToolFPC)=0 then begin
    if FPCMsgFilePool=nil then exit;
    CurMsgFile:=FPCMsgFilePool.LoadCurrentEnglishFile(false,nil);
    if CurMsgFile=nil then exit;
    try
      MsgItem:=CurMsgFile.GetMsg(MsgID);
      if MsgItem=nil then exit;
      Result:=MsgItem.Pattern;
    finally
      FPCMsgFilePool.UnloadFile(CurMsgFile);
    end;
  end;
end;

class function TIDEFPCParser.Priority: integer;
begin
  Result:=SubToolFPCPriority;
end;

class function TIDEFPCParser.MsgLineIsId(Msg: TMessageLine; MsgId: integer; out
  Value1, Value2: string): boolean;

  function GetStr(FromPos, ToPos: PChar): string;
  begin
    if (FromPos=nil) or (FromPos=ToPos) then
      Result:=''
    else begin
      SetLength(Result,ToPos-FromPos);
      Move(FromPos^,Result[1],ToPos-FromPos);
    end;
  end;

var
  aFPCParser: TFPCParser;
  Pattern: String;
  VarStarts: PPChar;
  VarEnds: PPChar;
  s: String;
begin
  Value1:='';
  Value2:='';
  if Msg=nil then exit(false);
  if Msg.SubTool<>SubToolFPC then exit(false);
  if (Msg.MsgID<>MsgId)
  and (Msg.MsgID<>0) then exit(false);
  Result:=true;
  aFPCParser:=GetFPCParser(Msg);
  if aFPCParser=nil then exit;
  Pattern:=aFPCParser.GetFPCMsgIDPattern(MsgId);
  VarStarts:=GetMem(SizeOf(PChar)*10);
  VarEnds:=GetMem(SizeOf(PChar)*10);
  s:=Msg.Msg;
  Result:=FPCMsgFits(s,Pattern,VarStarts,VarEnds);
  if Result then begin
    Value1:=GetStr(VarStarts[1],VarEnds[1]);
    Value2:=GetStr(VarStarts[2],VarEnds[2]);
  end;
  Freemem(VarStarts);
  Freemem(VarEnds);
end;

function TIDEFPCParser.GetFPCMsgIDPattern(MsgID: integer): string;
var
  MsgItem: TFPCMsgItem;
begin
  Result:='';
  if MsgID<=0 then exit;
  if MsgFile=nil then exit;
  MsgItem:=MsgFile.GetMsg(MsgID);
  if MsgItem=nil then exit;
  Result:=MsgItem.Pattern;
end;

class function TIDEFPCParser.GetFPCMsgPattern(Msg: TMessageLine): string;
var
  aFPCParser: TFPCParser;
begin
  Result:='';
  if Msg.MsgID<=0 then exit;
  aFPCParser:=GetFPCParser(Msg);
  if aFPCParser=nil then exit;
  Result:=aFPCParser.GetFPCMsgIDPattern(Msg.MsgID);
end;

class function TIDEFPCParser.GetFPCMsgValue1(Msg: TMessageLine): string;
begin
  Result:='';
  if Msg.MsgID<=0 then exit;
  if Msg.SubTool<>SubToolFPC then exit;
  if not etFPCMsgParser.GetFPCMsgValue1(Msg.Msg,GetFPCMsgPattern(Msg),Result) then
    Result:='';
end;

class function TIDEFPCParser.GetFPCMsgValues(Msg: TMessageLine; out Value1,
  Value2: string): boolean;
begin
  Result:=false;
  if Msg.MsgID<=0 then exit;
  if Msg.SubTool<>SubToolFPC then exit;
  Result:=etFPCMsgParser.GetFPCMsgValues(Msg.Msg,GetFPCMsgPattern(Msg),Value1,Value2);
end;

initialization
  IDEFPCParser:=TIDEFPCParser;
finalization
  FreeAndNil(FPCMsgFilePool)

end.

