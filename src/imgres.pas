unit imgres;

{$mode objfpc}{$H+}
{$modeSwitch advancedRecords}

interface

uses
  Classes, SysUtils, Types, SyncObjs, BGRABitmap, BGRABitmapTypes,
  threading.dispatcher;

const
  IMGRESVER = '1.9';
  IMGRESCPR = 'imgres V'+IMGRESVER+' © 2019 Jan Schirrmacher, www.atomek.de';

  PROGRESSSTEPSPERFILE = 3;

const
  DEFAULTSIZE           = 640;
  DEFAULTPNGCOMPRESSION = 2;
  DEFAULTJPGQUALITY     = 75;
  DEFAULTMRKSIZE        = 20.0;
  DEFAULTMRKX           = 98.0;
  DEFAULTMRKY           = 98.0;
  DEFAULTMRKALPHA       = 50.0;

type

  TSizes = array of integer;

  { TImgRes }

  TPrintEvent = procedure(Sender :TObject; const Line :string) of object;
  TProgressEvent = procedure(Sender :TObject; Progress :single) of object;

  TImgRes = class
  private type
    TResampleTask = class;

    TParams = record
      SrcFilenames :TStringList;
      DstFolder :string;
      Sizes :TSizes;
      JpgQuality :integer;
      PngCompression :integer;
      MrkFilename :string;
      MrkFilenameDependsOnSize :boolean; // if MrkFilename contains %SIZE%
      MrkSize :single;
      MrkX :single;
      MrkY :single;
      MrkAlpha :single;
      ThreadCount: integer;
    end;

    // Cached objects while execution, shared by the workers. This is, that
    // Bitmaps are loaded only once, not by every Worker
    TSharedTasks = class
    private
      FImgRes :TImgRes;
      FSrcImgsSection :TCriticalSection;
      FSrcImgs :array of TBGRABitmap;
      FMrkImgsSection :TCriticalSection;
      FMrkImgs :array of TBGRABitmap; // cached for each size
      FDstFoldersSection :TCriticalSection;
      FDstFolders :array of string;   // cached for each size
    public
      constructor Create(AImgRes :TImgRes);
      destructor Destroy; override;
      function GetSrcImg(Task :TResampleTask) :TBGRABitmap;
      function GetMrkImg(Task :TResampleTask) :TBGRABitmap;
      function GetDstFolder(Task :TResampleTask) :string;
    end;

    { TResampleTask }

    TResampleTask = class(TCustomTask)
    private
      FSharedTasks :TSharedTasks;
      FSrcFilenameIndex :integer;
      FSizeIndex :integer;
    protected
      function Execute(Context :TContext) :boolean; override;
      function GetTaskSteps :integer; override;
    public
      constructor Create(SharedTasks :TSharedTasks; const SrcFilenameIndex, SizeIndex :integer);
      property SrcIdx :integer read FSrcFilenameIndex;
      property DstIdx :integer read FSizeIndex;
    end;

  private
    FParams :TParams;
    FCancel :boolean;
    FOnPrint :TPrintEvent;
    FOnProgress :TProgressEvent;
    function GetSizes: string;
    function GetSrcFilenames: TStrings;
    procedure SetMrkFilename(AValue: string);
    procedure SetSizes(AValue: string);
    procedure SetJpgQuality(AValue: integer);
    procedure SetPngCompression(AValue: integer);
    procedure SetMrkSize(AValue: single);
    procedure SetMrkX(AValue: single);
    procedure SetMrkY(AValue: single);
    procedure SetMrkAlpha(AValue: single);
    procedure SetSrcFilnames(AValue: TStrings);
    procedure SetThreadCount(AValue: integer);
    function ResampleImg(Img :TBgraBitmap; const Size :TSize) :TBgraBitmap;
    class function CalcResamplingSize(const Size :TSize; LongWidth :integer) :TSize;
    procedure OnTaskPrint(Sender :TObject; WorkerId: integer; const Line :string; Level :TLevel);
    procedure OnTaskProgress(Sender :TObject; Progress :single);
  public
    constructor Create;
    destructor Destroy; override;
    class function GetVersion: string;
    function Execute :boolean; overload;
    procedure Cancel;
    class function TryStrToPngCompression(const Str :string; out Value :integer) :boolean;
    class function PngCompressionToStr(const Value :integer) :string;
    property SrcFilenames :TStrings read GetSrcFilenames write SetSrcFilnames;
    property DstFolder :string read FParams.DstFolder write FParams.DstFolder;
    property Sizes :string read GetSizes write SetSizes;
    property JpgQuality :integer read FParams.JpgQuality write SetJpgQuality;
    property PngCompression :integer read FParams.PngCompression write SetPngCompression;
    property MrkFilename :string read FParams.MrkFilename write SetMrkFilename;
    property MrkSize :single read FParams.MrkSize write SetMrkSize;
    property MrkX :single read FParams.MrkX write SetMrkX;
    property MrkY :single read FParams.MrkY write SetMrkY;
    property MrkAlpha :single read FParams.MrkAlpha write SetMrkAlpha;
    property ThreadCount :integer read FParams.ThreadCount write SetThreadCount;
    property OnPrint :TPrintEvent read FOnPrint write FOnPrint;
    property OnProgress :TProgressEvent read FOnProgress write FOnProgress;
  end;

function TrySizesStrToSizes(const Str :string; out Values :TSizes) :boolean;
function SizesToSizesStr(const Sizes :TSizes) :string;

implementation

uses
  ZStream, FPWriteJpeg, FPWritePng, FPImage, strutils, utils,
  generics.collections;

const
  PNGCOMPRS :array[0..3] of string = ('none', 'fastest', 'default', 'max');

type
  TIntegerArrayHelper = specialize TArrayHelper<Integer>;

function TrySizesStrToSizes(const Str :string; out Values :TSizes) :boolean;
var
  Raw :TIntegerDynArray;
  i, n :integer;
begin
  if not StrToIntegerArray(Str, ',', Raw) then Exit(false);
  for i:=0 to High(Raw) do if Raw[i]<1 then Exit(false);

  // Sort...
  TIntegerArrayHelper.Sort(Raw);

  // Remove doublettes
  if Length(Raw)>0 then begin
    n := 1;
    SetLength(Values, 1);
    Values[0] := Raw[0];
    for i:=1 to High(Raw) do begin
      if Raw[i]<>Raw[i-1] then begin
        SetLength(Values, n+1);
        Values[n] := Raw[i];
        inc(n);
       end;
    end;
  end;

  result := true;
end;

function SizesToSizesStr(const Sizes :TSizes) :string;
var
  i :integer;
begin
  if Length(Sizes)=0 then
    Exit('');
  result := IntToStr(Sizes[0]);
  for i:=1 to High(Sizes) do
    result := result + ', ' + IntToStr(Sizes[i]);
end;

{ TImgRes.TResampleTask }

function TImgRes.TResampleTask.Execute(Context: TContext): boolean;
var
  SrcImg :TBGRABitmap;
  SrcFilename :string;
  DstFolder :string;
  FileExt :string;
  DstFiletitle :string;
  DstFilename :string;
  DstImg :TBGRABitmap;
  Writer :TFPCustomImageWriter;
  Size :integer;
  SrcSize :TSize;
  DstSize :TSize;
  MrkImg :TBGRABitmap;
  MrkRectSize :TSize;
  MrkRect :TRect;
  Params :^TParams;
//  i :integer;
begin
  Writer := nil;
  DstImg := nil;
  result := false;
  try
    Params := @FSharedTasks.FImgRes.FParams;

    if Context.Aborted then
      Exit;

    // Destination Folder
    DstFolder := FSharedTasks.GetDstFolder(self);

    // Source File
    SrcImg := FSharedTasks.GetSrcImg(self);
    SrcFilename := Params^.SrcFilenames[SrcIdx];

    if Context.Aborted then
      Exit;
    Progress(1);

    // Create Writer depending on file extension
    FileExt := LowerCase(ExtractFileExt(SrcFilename));
    if (FileExt = '.jpg') or (FileExt = '.jpeg') then begin

      // Jpg-options
      Writer := TFPWriterJPEG.Create;
      with TFPWriterJPEG(Writer) do
        CompressionQuality := TFPJPEGCompressionQuality(Params^.JpgQuality);

    end else if FileExt = '.png' then begin

      // Png-options
      Writer := TFPWriterPNG.Create;
      with TFPWriterPNG(Writer) do
        CompressionLevel := ZStream.TCompressionLevel(Params^.PngCompression);
    end else
      raise Exception.CreateFmt('Format %s not supported.', [FileExt]);

    // Calculate new size
    Size := Params^.Sizes[FSizeIndex];
    SrcSize := TSize.Create(SrcImg.Width, SrcImg.Height);
    DstSize := CalcResamplingSize(SrcSize, Size);

    ////////////////////////////////////////////////////////////////////////////
    // Resampling...
    Print(Format('Resampling ''%s'' from %dx%d to %dx%d...', [
      ExtractFilename(SrcFilename), SrcSize.cx, SrcSize.cy, DstSize.cx, DstSize.cy]));
    DstImg := FSharedTasks.FImgRes.ResampleImg(SrcImg, DstSize);
    ////////////////////////////////////////////////////////////////////////////
    if Context.Aborted then
      Exit;
    Progress(1);

    ////////////////////////////////////////////////////////////////////////////
    // Watermark
    if Params^.MrkFilename<>'' then begin
      MrkImg := FSharedTasks.GetMrkImg(self);

      // Watermark size inpercent of the width or original size if MrkSize=0.0
      if Params^.MrkSize<>0.0 then begin
        MrkRectSize.cx := round(DstSize.cx*Params^.MrkSize/100.0);
        MrkRectSize.cy := round(DstSize.cx*Params^.MrkSize/100.0 * MrkImg.Height/MrkImg.Width);
      end else begin
        MrkRectSize.cx := MrkImg.Width;
        MrkRectSize.cy := MrkImg.Height;
      end;
      MrkRect.Left := round((DstSize.cx - MrkRectSize.cx) * Params^.MrkX/100.0);
      MrkRect.Top := round((DstSize.cy - MrkRectSize.cy) * Params^.MrkY/100.0);
      MrkRect.Width := MrkRectSize.cx;
      MrkRect.Height := MrkRectSize.cy;
      Print(Format('Watermarking ''%s''...', [
        ExtractFilename(SrcFilename), SrcSize.cx, SrcSize.cy, DstSize.cx, DstSize.cy]));
      DstImg.StretchPutImage(MrkRect, MrkImg, dmLinearBlend, round(255*Params^.MrkAlpha/100.0));
    end;
    if Context.Aborted then
      Exit;
    Progress(1);
    ////////////////////////////////////////////////////////////////////////////

    // Saving...
    DstFiletitle := ExtractFilename(SrcFilename);
    DstFilename := IncludeTrailingPathDelimiter(DstFolder) + DstFiletitle;
    Print(Format('Saving ''%s''...' , [DstFilename]));
    DstImg.SaveToFile(DstFilename, Writer);
    Progress(1);

    result := true;
  finally
    if result = false then
      Beep;
    Writer.Free;
    DstImg.Free;
  end;
end;

function TImgRes.TResampleTask.GetTaskSteps: integer;
begin
  result := 4; // Loading, Resampling, Watermarking, Saving
end;

constructor TImgRes.TResampleTask.Create(SharedTasks :TSharedTasks; const SrcFilenameIndex, SizeIndex: integer);
begin
  inherited Create;
  FSharedTasks := SharedTasks;
  FSrcFilenameIndex := SrcFilenameIndex;
  FSizeIndex := SizeIndex;
end;

{ TImgRes.TSharedTasks }

constructor TImgRes.TSharedTasks.Create(AImgRes: TImgRes);
begin
  FImgRes := AImgRes;
  FSrcImgsSection := TCriticalSection.Create;
  SetLength(FSrcImgs, FImgRes.SrcFilenames.Count);
  FMrkImgsSection := TCriticalSection.Create;
  if FImgRes.FParams.MrkFilenameDependsOnSize then
    SetLength(FMrkImgs, Length(FImgRes.FParams.Sizes))
  else
    SetLength(FMrkImgs, 1);
  FDstFoldersSection := TCriticalSection.Create;
  SetLength(FDstFolders, Length(FImgRes.FParams.Sizes));
end;

destructor TImgRes.TSharedTasks.Destroy;
var
  i :integer;
begin
  for i:=0 to High(FSrcImgs) do
    FSrcImgs[i].Free;
  for i:=0 to High(FMrkImgs) do
    FMrkImgs[i].Free;
  FSrcImgsSection.Free;
  FMrkImgsSection.Free;
  FDstFoldersSection.Free;
  inherited Destroy;
end;

function TImgRes.TSharedTasks.GetSrcImg(Task :TResampleTask): TBGRABitmap;
var
  SrcFilename :string;
begin
  FSrcImgsSection.Enter;
  try
    SrcFilename := FImgRes.FParams.SrcFilenames[Task.FSrcFilenameIndex];
    if not Assigned(FSrcImgs[Task.FSrcFilenameIndex]) then begin
      Task.Print(Format('Loading %s...', [ExtractFilename(SrcFilename)]));
      FSrcImgs[Task.FSrcFilenameIndex] := TBGRABitmap.Create(SrcFilename);
    end;
    result := FSrcImgs[Task.FSrcFilenameIndex];
  finally
    FSrcImgsSection.Leave;
  end;
end;

function TImgRes.TSharedTasks.GetMrkImg(Task :TResampleTask): TBGRABitmap;
var
  Filename :string;
  Index :integer;
begin
  FMrkImgsSection.Enter;
  try
    if FImgRes.FParams.MrkFilenameDependsOnSize then
      Index := Task.FSizeIndex
    else
      Index := 0;
    if not Assigned(FMrkImgs[Index]) then begin
      if FImgRes.FParams.MrkFilenameDependsOnSize then
        Filename := ReplaceStr(FImgRes.FParams.MrkFilename, '%SIZE%', IntToStr(FImgRes.FParams.Sizes[Index]))
      else
        Filename := FImgRes.FParams.MrkFilename;
      Task.Print(Format('Loading ''%s''...', [ExtractFilename(Filename)]));
      FMrkImgs[Index] := TBGRABitmap.Create(Filename);
    end;
    result := FMrkImgs[Index]
  finally
    FMrkImgsSection.Leave;
  end;
end;

function TImgRes.TSharedTasks.GetDstFolder(Task :TResampleTask): string;
var
  DstFolder :string;
  Index :integer;
begin
  FDstFoldersSection.Enter;
  try
    Index := Task.FSizeIndex;
    if FDstFolders[Index]='' then begin
      DstFolder := ReplaceStr(FImgRes.FParams.DstFolder, '%SIZE%', IntToStr(FImgRes.FParams.Sizes[Index]));
      Task.Print(Format('Creating folder ''%s''...', [DstFolder]));
      ForceDirectories(DstFolder);
      FDstFolders[Index] := DstFolder;
    end;
    result := FDstFolders[Index];
  finally
    FDstFoldersSection.Leave;
  end;
end;

{ TImgRes }

class function TImgRes.CalcResamplingSize(const Size :TSize; LongWidth :integer) :TSize;
var
  f :single;
begin
  f := Size.cx/Size.cy;
  if f>=1.0 then begin
    result.cx := LongWidth;
    result.cy := round(LongWidth/f);
  end else begin
    result.cy := LongWidth;
    result.cx := round(LongWidth*f);
  end;
end;

procedure TImgRes.OnTaskPrint(Sender: TObject; WorkerId: integer; const Line: string; Level: TLevel);
const
  LEVELSTRS :array[TLevel] of string = ('Hint - ', '', 'Warning - ', 'Abort - ', 'Fatal - ');
begin
  if Assigned(FOnPrint) then begin
    FOnPrint(self, Format('%d: %s%s', [WorkerId, LEVELSTRS[Level], Line]));
  end;
end;

procedure TImgRes.OnTaskProgress(Sender: TObject; Progress: single);
begin
  if Assigned(FOnProgress) then begin
    FOnProgress(self, Progress);
    if FCancel then
      (Sender as TDispatcher).Abort;
  end;
end;

procedure TImgRes.SetThreadCount(AValue: integer);
begin
  if FParams.ThreadCount = AValue then Exit;
  if AValue<-1 then
    raise Exception.Create('Invalid threadcount.');
  FParams.ThreadCount := AValue;
end;

function TImgRes.ResampleImg(Img :TBgraBitmap; const Size :TSize) :TBgraBitmap;
begin
  Img.ResampleFilter := rfLanczos2;
  result := Img.Resample(Size.cx, Size.cy) as TBGRABitmap;
end;

constructor TImgRes.Create;
begin
  FParams.SrcFilenames   := TStringList.Create;
  SetLength(FParams.Sizes, 1);
  FParams.Sizes[0]       := DEFAULTSIZE;
  FParams.JpgQuality     := DEFAULTJPGQUALITY;
  FParams.PngCompression := DEFAULTPNGCOMPRESSION;
  FParams.MrkFilename    := '';
  FParams.MrkSize        := DEFAULTMRKSIZE;
  FParams.MrkX           := DEFAULTMRKX;
  FParams.MrkY           := DEFAULTMRKY;
  FParams.MrkAlpha       := DEFAULTMRKALPHA;
end;

destructor TImgRes.Destroy;
begin
  FParams.SrcFilenames.Free;
  inherited Destroy;
end;

function TImgRes.Execute :boolean; overload;
var
  SharedTasks :TSharedTasks;
  Tasks :TTasks;
  Dispatcher :TDispatcher;
  i, j, n, m :integer;
begin
  FCancel := false;
  SharedTasks := TSharedTasks.Create(self);
  Tasks := TTasks.Create;
  Dispatcher := TDispatcher.Create;
  try
    n := FParams.SrcFilenames.Count;
    m := Length(FParams.Sizes);

    // For each SrcFilename/Size create a task
    Tasks.Capacity := n*m;
    for i:=0 to n-1 do
      for j:=0 to m-1 do
        Tasks.Add(TResampleTask.Create(SharedTasks, i, j));

    Dispatcher.OnPrint := @OnTaskPrint;
    Dispatcher.OnProgress := @OnTaskProgress;
    Dispatcher.MaxWorkerCount := ThreadCount;
//    Dispatcher.StopOnError := true;
    result := Dispatcher.Execute(Tasks);

  finally
    Dispatcher.Free;
    Tasks.Free;
    SharedTasks.Free;
  end;

  result := true;
end;

procedure TImgRes.Cancel;
begin
  FCancel := true;
end;

class function TImgRes.TryStrToPngCompression(const Str: string; out Value: integer): boolean;
var
  i :integer;
begin
  for i:=0 to High(PNGCOMPRS) do
    if SameText(PNGCOMPRS[i], Str) then begin
        Value := i;
        Exit(true);
    end;
  result := false;
end;

class function TImgRes.PngCompressionToStr(const Value :integer) :string;
begin
  if (Value<0) or (Value>High(PNGCOMPRS)) then
    raise Exception.CreateFmt('Invalid png compression %d (0..3).', [Value]);
  result := PNGCOMPRS[Value];
end;

procedure TImgRes.SetSizes(AValue :string);
begin
  if not TrySizesStrToSizes(AValue, FParams.Sizes) then
    raise Exception.Create(Format('Invalid sizes ''%s''.', [AValue]));
end;

function TImgRes.GetSizes: string;
begin
  result := SizesToSizesStr(FParams.Sizes);
end;

function TImgRes.GetSrcFilenames: TStrings;
begin
  result := FParams.SrcFilenames;
end;

procedure TImgRes.SetMrkFilename(AValue: string);
begin
  if AValue=FParams.MrkFilename then Exit;
  FParams.MrkFilename := AValue;
  FParams.MrkFilenameDependsOnSize := Pos('%SIZE%', AValue)>0;
end;

procedure TImgRes.SetJpgQuality(AValue: integer);
begin
  if FParams.JpgQuality=AValue then Exit;
  if (AValue<1) or (AValue>100) then
    raise Exception.CreateFmt('Invalid jpg quality %d (1..100).', [AValue]);
  FParams.JpgQuality:=AValue;
end;

procedure TImgRes.SetPngCompression(AValue: integer);
begin
  if FParams.PngCompression=AValue then Exit;
  if (AValue<0) or (AValue>3) then
    raise Exception.CreateFmt('Invalid png compression %d (0..3).', [AValue]);
  FParams.PngCompression:=AValue;
end;

procedure TImgRes.SetMrkSize(AValue: single);
begin
  if FParams.MrkSize=AValue then Exit;
  if AValue<0.0 then AValue := 0.0;
  if AValue>100.0 then AValue := 100.0;
  FParams.MrkSize:=AValue;
end;

procedure TImgRes.SetMrkX(AValue: single);
begin
  if FParams.MrkX=AValue then Exit;
  FParams.MrkX:=AValue;
end;

procedure TImgRes.SetMrkY(AValue: single);
begin
  if FParams.MrkY=AValue then Exit;
  FParams.MrkY:=AValue;
end;

procedure TImgRes.SetMrkAlpha(AValue: single);
begin
  if FParams.MrkAlpha=AValue then Exit;
  if AValue<0.0 then AValue := 0.0;
  if AValue>100.0 then AValue := 100.0;
  FParams.MrkAlpha:=AValue;
end;

procedure TImgRes.SetSrcFilnames(AValue: TStrings);
begin
  FParams.SrcFilenames.Assign(AValue);
end;

class function TImgRes.GetVersion: string;
begin
  result := IMGRESVER;
end;

end.

