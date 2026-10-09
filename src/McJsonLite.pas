(* ******************************************************************************
  McJsonLite - small, JS-like, "never nil" JSON tree for Delphi / FPC.

  Derived in design from McJSON (c) 2021-2025 HydroByte Software, MIT License
  https://github.com/hydrobyte/McJSON
  Property names (Items, Values, AsString, AsInteger, AsNumber, AsBoolean,
  AsJSON, Key, Count, Add, Delete, ToString, LoadFromFile, SaveToFile) were
  kept compatible where possible.

  Rules:
  * Reading NEVER raises and NEVER returns nil. A missing key/index returns a
  "ghost" node: Kind = jkMissing, Exists = False, AsString = '', AsInteger
  = 0, AsBoolean = False, further ['x'] / [0] on it yield more ghosts.
  * Writing creates the path on demand:  J['a']['b'][2]['c'].AsInteger := 1;
  * Only the root must be freed. All nodes belong to the root. Do not keep
  node references after the node (or an ancestor) was deleted/cleared.
  * Parsing is lenient like JS: unquoted keys, single quotes, trailing commas.
  Output is always strict JSON.
  * Strings are stored UNescaped; escaping happens on output.
  * Not thread-safe (even reading may create ghost nodes).
  ****************************************************************************** *)
unit McJsonLite;

{$IFDEF FPC}
{$MODE DELPHI}
{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, Math, Variants,System.StrUtils;

type
  EJsonError = class(Exception);

  TJKind = (jkMissing, jkNull, jkString, jkNumber, jkBoolean, jkObject,
    jkArray);

  TJson = class;

  TJsonEnumerator = class
  private
    FNode: TJson;
    FIndex: Integer;
  public
    constructor Create(ANode: TJson);
    function GetCurrent: TJson;
    function MoveNext: Boolean;
    property Current: TJson read GetCurrent;
  end;

  TJson = class
  private
    FKind: TJKind;
    FKey: string;
    FValue: string;
    FStrings: TStringList; // Cache für AsStrings (Lesen)
    FChild: TList; // real children (object/array)
    FGhosts: TList; // ghost nodes created from this node
    FParent: TJson; // <> nil only for ghosts
    FByIdx: Boolean; // ghost: addressed by index
    FIdx: Integer; // ghost: index

    function Resolve: TJson; // concrete node or nil
    function Obtain: TJson; // concrete node, created if needed
    function ChildCount: Integer;
    function ChildAt(AIndex: Integer): TJson;
    function FindChild(const AKey: string): TJson;
    function NewChild(const AKey: string): TJson;
    function GhostFor(const AKey: string; AByIdx: Boolean;
      AIdx: Integer): TJson;
    function CreateKey(const AKey: string): TJson;
    function CreateIdx(AIdx: Integer): TJson;
    procedure ClearChildren;
    procedure BecomeContainer(AKind: TJKind);
    procedure SetScalar(AKind: TJKind; const AValue: string);
    procedure TakeFrom(ASource: TJson);

    function GetByVar(const AIndex: Variant): TJson;
    function GetByKey(const AKey: string): TJson;
    function GetByIdx(AIndex: Integer): TJson;
    function GetKind: TJKind;
    function GetExists: Boolean;
    function GetCount: Integer;
    function GetKey: string;
    function GetAsString: string;
    function GetAsInt64: Int64;
    function GetAsInteger: Integer;
    function GetAsNumber: Double;
    function GetAsBoolean: Boolean;
    function GetAsJSON: string;
    procedure SetAsString(const AValue: string);
    procedure SetAsInt64(AValue: Int64);
    procedure SetAsInteger(AValue: Integer);
    procedure SetAsNumber(AValue: Double);
    procedure SetAsBoolean(AValue: Boolean);
    procedure SetAsJSON(const AValue: string);

    function GetAsStrings: TStrings;
    procedure SetAsStrings(AValue: TStrings);

    procedure ParseValue(const S: string; var P: Integer);
    procedure ParseObject(const S: string; var P: Integer);
    procedure ParseArray(const S: string; var P: Integer);
    procedure WriteTo(var B: string; var N: Integer; AHuman: Boolean;
      ALevel: Integer);
  public
    constructor Create; overload;
    constructor Create(const AJson: string); overload;
    destructor Destroy; override;

    // navigation: never nil, never raises
    // J['key']  /  J[0]   (default property, string or integer index)
    property Item[const AIndex: Variant]: TJson read GetByVar; default;
    // typed variants of the same thing (no Variant conversion)
    property Values[const AKey: string]: TJson read GetByKey;
    property Items[AIndex: Integer]: TJson read GetByIdx;

    // inspection
    property Kind: TJKind read GetKind;
    property Exists: Boolean read GetExists; // False for missing/unset
    property Count: Integer read GetCount; // children of object/array
    property Key: string read GetKey;

    // typed access: reading converts leniently (default on failure),
    // writing creates the path and sets type + value
    property AsString: string read GetAsString write SetAsString;
    property AsInteger: Integer read GetAsInteger write SetAsInteger;
    property AsInt64: Int64 read GetAsInt64 write SetAsInt64;
    property AsNumber: Double read GetAsNumber write SetAsNumber;
    property AsBoolean: Boolean read GetAsBoolean write SetAsBoolean;
    property AsJSON: string read GetAsJSON write SetAsJSON;
    // raises EJsonError on bad input
    property AsStrings: TStrings read GetAsStrings write SetAsStrings;

    function SetObject: TJson;
    function SetArray: TJson;
    function SetNull: TJson;
    function Path(const APath: string; const ASep: string = '.'): TJson;
    function SetType(AKind: TJKind): TJson; // jkObject, jkArray, jkNull
    function HasKey(const AKey: string): Boolean;
    // key present (null counts), creates nothing
    function Add: TJson; overload; // wie bisher: leeres Element
    function Add(const AValue: string): TJson; overload;
    // String anhängen, liefert das neue Element
    function Add(AList: TStrings): TJson; overload;
    // alle Strings anhängen, liefert Self    function  Delete(const AKey: string): Boolean; overload;
    function Delete(const AKey: string): Boolean; overload;
    function Delete(AIndex: Integer): Boolean; overload;
    procedure Clear;

    function TryParse(const AJson: string): Boolean;
    // never raises, data untouched on failure
    function ToString(AHuman: Boolean = False): string; reintroduce; overload;
    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string; AHuman: Boolean = True);

    function GetEnumerator: TJsonEnumerator;
  end;

implementation

const
  KIND_NAMES: array [TJKind] of string = ('missing', 'null', 'string', 'number',
    'boolean', 'object', 'array');

var
  GFmt: TFormatSettings; // invariant: '.' as decimal separator

  { ---------------------------------------------------------------------------- }
  { helpers }
  { ---------------------------------------------------------------------------- }

procedure ParseError(const AMsg: string; APos: Integer);
begin
  raise EJsonError.CreateFmt('JSON error: %s at position %d', [AMsg, APos]);
end;

function IsDigit(c: Char): Boolean;
begin
  Result := (c >= '0') and (c <= '9');
end;

function IsIdentChar(c: Char): Boolean;
begin
  Result := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
    ((c >= '0') and (c <= '9')) or (c = '_') or (c = '$') or (c > #127);
end;

procedure SkipWS(const S: string; var P: Integer);
var
  L: Integer;
begin
  L := Length(S);
  while (P <= L) and ((S[P] = ' ') or (S[P] = #9) or (S[P] = #10) or
    (S[P] = #13)) do
    Inc(P);
end;

function HexVal(c: Char): Integer;
begin
  case c of
    '0' .. '9':
      Result := Ord(c) - Ord('0');
    'a' .. 'f':
      Result := Ord(c) - Ord('a') + 10;
    'A' .. 'F':
      Result := Ord(c) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

// growable string buffer: B = storage, N = used length
procedure BufAdd(var B: string; var N: Integer; const T: string);
var
  L: Integer;
begin
  L := Length(T);
  if L = 0 then
    Exit;
  if N + L > Length(B) then
    SetLength(B, (N + L) * 2 + 64);
  Move(T[1], B[N + 1], L * SizeOf(Char));
  Inc(N, L);
end;

procedure BufAddQuoted(var B: string; var N: Integer; const S: string);
var
  i, St: Integer;
  c: Char;
  Esc: string;
begin
  BufAdd(B, N, '"');
  St := 1;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c = '"') or (c = '\') or (c < ' ') then
    begin
      BufAdd(B, N, Copy(S, St, i - St));
      case c of
        '"':
          Esc := '\"';
        '\':
          Esc := '\\';
        #8:
          Esc := '\b';
        #9:
          Esc := '\t';
        #10:
          Esc := '\n';
        #12:
          Esc := '\f';
        #13:
          Esc := '\r';
      else
        Esc := '\u' + IntToHex(Ord(c), 4);
      end;
      BufAdd(B, N, Esc);
      St := i + 1;
    end;
  end;
  BufAdd(B, N, Copy(S, St, Length(S) - St + 1));
  BufAdd(B, N, '"');
end;

// reads "..." or '...' starting at S[P] (the opening quote), unescapes
procedure ParseString(const S: string; var P: Integer; out Res: string);
var
  Q, c: Char;
  L, St, Code, Code2, k, h: Integer;
  B: string;
  N: Integer;
begin
  L := Length(S);
  Q := S[P];
  Inc(P);
  St := P;
  B := '';
  N := 0;
  while True do
  begin
    if P > L then
      ParseError('unterminated string', P);
    c := S[P];
    if c = Q then
      Break
    else if c = '\' then
    begin
      BufAdd(B, N, Copy(S, St, P - St));
      Inc(P);
      if P > L then
        ParseError('unterminated string', P);
      case S[P] of
        'b':
          BufAdd(B, N, #8);
        'f':
          BufAdd(B, N, #12);
        'n':
          BufAdd(B, N, #10);
        'r':
          BufAdd(B, N, #13);
        't':
          BufAdd(B, N, #9);
        '"', '''', '\', '/':
          BufAdd(B, N, S[P]);
        'u':
          begin
            if P + 4 > L then
              ParseError('bad \u escape', P);
            Code := 0;
            for k := 1 to 4 do
            begin
              h := HexVal(S[P + k]);
              if h < 0 then
                ParseError('bad \u escape', P);
              Code := Code * 16 + h;
            end;
            Inc(P, 4);
{$IFDEF UNICODE}
            BufAdd(B, N, Char(Code));
            // UTF-16 string: surrogates just pass through
{$ELSE}
            // FPC / ANSI string holds UTF-8
            if (Code >= $D800) and (Code <= $DBFF) and (P + 6 <= L) and
              (S[P + 1] = '\') and (S[P + 2] = 'u') then
            begin
              Code2 := 0;
              for k := 3 to 6 do
              begin
                h := HexVal(S[P + k]);
                if h < 0 then
                  ParseError('bad \u escape', P);
                Code2 := Code2 * 16 + h;
              end;
              if (Code2 >= $DC00) and (Code2 <= $DFFF) then
              begin
                BufAdd(B, N, UTF8Encode(WideString(WideChar(Code)) +
                  WideString(WideChar(Code2))));
                Inc(P, 6);
              end
              else
                BufAdd(B, N, UTF8Encode(WideString(WideChar(Code))));
            end
            else
              BufAdd(B, N, UTF8Encode(WideString(WideChar(Code))));
{$ENDIF}
          end;
      else
        ParseError('invalid escape', P);
      end;
      Inc(P);
      St := P;
    end
    else if c < ' ' then
      ParseError('control character in string', P)
    else
      Inc(P);
  end;
  BufAdd(B, N, Copy(S, St, P - St));
  Inc(P); // closing quote
  SetLength(B, N);
  Res := B;
end;

procedure ParseNumber(const S: string; var P: Integer; out Raw: string);
var
  St, L: Integer;
begin
  L := Length(S);
  St := P;
  if S[P] = '-' then
    Inc(P);
  if (P > L) or not IsDigit(S[P]) then
    ParseError('invalid number', P);
  if S[P] = '0' then
    Inc(P)
  else
    while (P <= L) and IsDigit(S[P]) do
      Inc(P);
  if (P <= L) and (S[P] = '.') then
  begin
    Inc(P);
    if (P > L) or not IsDigit(S[P]) then
      ParseError('invalid number', P);
    while (P <= L) and IsDigit(S[P]) do
      Inc(P);
  end;
  if (P <= L) and ((S[P] = 'e') or (S[P] = 'E')) then
  begin
    Inc(P);
    if (P <= L) and ((S[P] = '+') or (S[P] = '-')) then
      Inc(P);
    if (P > L) or not IsDigit(S[P]) then
      ParseError('invalid number', P);
    while (P <= L) and IsDigit(S[P]) do
      Inc(P);
  end;
  Raw := Copy(S, St, P - St);
end;

procedure ParseIdent(const S: string; var P: Integer; out Id: string);
var
  St, L: Integer;
begin
  L := Length(S);
  St := P;
  while (P <= L) and IsIdentChar(S[P]) do
    Inc(P);
  if P = St then
    ParseError('unexpected character', P);
  Id := Copy(S, St, P - St);
end;

{ ---------------------------------------------------------------------------- }
{ TJsonEnumerator }
{ ---------------------------------------------------------------------------- }

constructor TJsonEnumerator.Create(ANode: TJson);
begin
  inherited Create;
  FNode := ANode;
  FIndex := -1;
end;

function TJsonEnumerator.MoveNext: Boolean;
begin
  Inc(FIndex);
  Result := FIndex < FNode.Count;
end;

function TJsonEnumerator.GetCurrent: TJson;
begin
  Result := FNode.Items[FIndex];
end;

{ ---------------------------------------------------------------------------- }
{ TJson - lifetime }
{ ---------------------------------------------------------------------------- }

constructor TJson.Create;
begin
  inherited Create;
  FKind := jkMissing;
end;

constructor TJson.Create(const AJson: string);
begin
  Create;
  SetAsJSON(AJson);
end;

destructor TJson.Destroy;
var
  i: Integer;
begin
  ClearChildren;
  if FGhosts <> nil then
  begin
    for i := 0 to FGhosts.Count - 1 do
      TJson(FGhosts[i]).Free;
    FGhosts.Free;
  end;
  inherited Destroy;
end;

procedure TJson.ClearChildren;
var
  i: Integer;
begin
  if FChild <> nil then
  begin
    for i := 0 to FChild.Count - 1 do
      TJson(FChild[i]).Free;
    FChild.Free;
    FChild := nil;
  end;
end;

procedure TJson.BecomeContainer(AKind: TJKind);
begin
  ClearChildren;
  FKind := AKind;
  FValue := '';
end;

procedure TJson.TakeFrom(ASource: TJson);
begin
  ClearChildren;
  FKind := ASource.FKind;
  FValue := ASource.FValue;
  FChild := ASource.FChild;
  ASource.FChild := nil;
end;

{ ---------------------------------------------------------------------------- }
{ TJson - ghost / lookup machinery }
{ ---------------------------------------------------------------------------- }

function TJson.ChildCount: Integer;
begin
  if FChild = nil then
    Result := 0
  else
    Result := FChild.Count;
end;

function TJson.ChildAt(AIndex: Integer): TJson;
begin
  Result := nil;
  if (FKind in [jkObject, jkArray]) and (FChild <> nil) and (AIndex >= 0) and
    (AIndex < FChild.Count) then
    Result := TJson(FChild[AIndex]);
end;

// searches backwards: with duplicate keys the last one wins (like JS)
function TJson.FindChild(const AKey: string): TJson;
var
  i: Integer;
begin
  Result := nil;
  if (FKind <> jkObject) or (FChild = nil) then
    Exit;
  for i := FChild.Count - 1 downto 0 do
    if TJson(FChild[i]).FKey = AKey then
    begin
      Result := TJson(FChild[i]);
      Exit;
    end;
end;

function TJson.NewChild(const AKey: string): TJson;
begin
  if FChild = nil then
    FChild := TList.Create;
  Result := TJson.Create;
  Result.FKey := AKey;
  FChild.Add(Result);
end;

function TJson.GhostFor(const AKey: string; AByIdx: Boolean;
  AIdx: Integer): TJson;
var
  i: Integer;
  G: TJson;
begin
  if FGhosts = nil then
    FGhosts := TList.Create;
  for i := 0 to FGhosts.Count - 1 do
  begin
    G := TJson(FGhosts[i]);
    if (G.FByIdx = AByIdx) and (G.FIdx = AIdx) and (G.FKey = AKey) then
    begin
      Result := G;
      Exit;
    end;
  end;
  G := TJson.Create;
  G.FParent := Self;
  G.FByIdx := AByIdx;
  G.FIdx := AIdx;
  G.FKey := AKey;
  FGhosts.Add(G);
  Result := G;
end;

// a ghost never caches its target: it is looked up again on every access, so
// it always reflects the current tree
function TJson.Resolve: TJson;
var
  P: TJson;
begin
  Result := nil;
  if FParent = nil then
  begin
    Result := Self;
    Exit;
  end;
  P := FParent.Resolve;
  if P = nil then
    Exit;
  if FByIdx then
    Result := P.ChildAt(FIdx)
  else
    Result := P.FindChild(FKey);
end;

function TJson.CreateKey(const AKey: string): TJson;
begin
  if FKind in [jkMissing, jkNull] then
    BecomeContainer(jkObject)
  else if FKind <> jkObject then
    raise EJsonError.CreateFmt
      ('Cannot set property "%s": node is %s, not an object',
      [AKey, KIND_NAMES[FKind]]);
  Result := NewChild(AKey);
end;

function TJson.CreateIdx(AIdx: Integer): TJson;
begin
  if AIdx < 0 then
    raise EJsonError.CreateFmt('Invalid array index %d', [AIdx]);
  if FKind in [jkMissing, jkNull] then
    BecomeContainer(jkArray)
  else if FKind <> jkArray then
    raise EJsonError.CreateFmt('Cannot set index %d: node is %s, not an array',
      [AIdx, KIND_NAMES[FKind]]);
  while ChildCount < AIdx do
    NewChild('').FKind := jkNull; // JS-like: gaps are filled with null
  Result := NewChild('');
end;

function TJson.Obtain: TJson;
var
  P: TJson;
begin
  Result := Resolve;
  if Result <> nil then
    Exit;
  P := FParent.Obtain;
  if FByIdx then
    Result := P.CreateIdx(FIdx)
  else
    Result := P.CreateKey(FKey);
end;

{ ---------------------------------------------------------------------------- }
{ TJson - navigation / inspection }
{ ---------------------------------------------------------------------------- }

function TJson.GetByVar(const AIndex: Variant): TJson;
var
  I64: Int64;
begin
  if VarIsStr(AIndex) then
    Result := GetByKey(VarToStr(AIndex))
  else if VarIsOrdinal(AIndex) then
  begin
    I64 := AIndex;
    if (I64 >= Low(Integer)) and (I64 <= High(Integer)) then
      Result := GetByIdx(Integer(I64))
    else
      Result := GetByIdx(-1);
  end
  else
    Result := GetByKey(VarToStr(AIndex));
  // anything else: treat as key, never raise
end;

function TJson.GetByKey(const AKey: string): TJson;
var
  R: TJson;
begin
  Result := nil;
  R := Resolve;
  if R <> nil then
    Result := R.FindChild(AKey);
  if Result = nil then
    Result := GhostFor(AKey, False, 0);
end;

function TJson.GetByIdx(AIndex: Integer): TJson;
var
  R: TJson;
begin
  Result := nil;
  R := Resolve;
  if R <> nil then
    Result := R.ChildAt(AIndex);
  if Result = nil then
    Result := GhostFor('', True, AIndex);
end;

function TJson.GetKind: TJKind;
var
  R: TJson;
begin
  R := Resolve;
  if R = nil then
    Result := jkMissing
  else
    Result := R.FKind;
end;

function TJson.GetExists: Boolean;
begin
  Result := GetKind <> jkMissing;
end;

function TJson.GetCount: Integer;
var
  R: TJson;
begin
  R := Resolve;
  if R = nil then
    Result := 0
  else
    Result := R.ChildCount;
end;

function TJson.GetKey: string;
begin
  Result := FKey;
end;

{ ---------------------------------------------------------------------------- }
{ TJson - typed getters (lenient) }
{ ---------------------------------------------------------------------------- }

function TJson.GetAsString: string;
var
  R: TJson;
begin
  Result := '';
  R := Resolve;
  if (R <> nil) and (R.FKind in [jkString, jkNumber, jkBoolean]) then
    Result := R.FValue;
end;

function TJson.GetAsNumber: Double;
var
  R: TJson;
begin
  Result := 0;
  R := Resolve;
  if R = nil then
    Exit;
  case R.FKind of
    jkNumber, jkString:
      if not TryStrToFloat(Trim(R.FValue), Result, GFmt) then
        Result := 0;
    jkBoolean:
      if R.FValue = 'true' then
        Result := 1;
  end;
end;

function TJson.GetAsInt64: Int64;
var
  R: TJson;
  D: Double;
begin
  Result := 0;
  R := Resolve;
  if R = nil then
    Exit;
  case R.FKind of
    jkNumber, jkString:
      if not TryStrToInt64(Trim(R.FValue), Result) then
      begin
        D := GetAsNumber; // "1.9" / "1e3" -> truncate
        if (D > -9.2E18) and (D < 9.2E18) then
          Result := Trunc(D)
        else
          Result := 0;
      end;
    jkBoolean:
      if R.FValue = 'true' then
        Result := 1;
  end;
end;

function TJson.GetAsInteger: Integer;
var
  V: Int64;
begin
  V := GetAsInt64;
  if (V >= Low(Integer)) and (V <= High(Integer)) then
    Result := Integer(V)
  else
    Result := 0;
end;

function TJson.GetAsBoolean: Boolean;
var
  R: TJson;
begin
  Result := False;
  R := Resolve;
  if R = nil then
    Exit;
  case R.FKind of
    jkBoolean:
      Result := R.FValue = 'true';
    jkNumber:
      Result := GetAsNumber <> 0;
    jkString:
      Result := SameText(Trim(R.FValue), 'true') or (Trim(R.FValue) = '1');
  end;
end;

function TJson.GetAsJSON: string;
begin
  Result := ToString(False);
end;

{ ---------------------------------------------------------------------------- }
{ TJson - setters (create the path on demand) }
{ ---------------------------------------------------------------------------- }

procedure TJson.SetScalar(AKind: TJKind; const AValue: string);
var
  N: TJson;
begin
  N := Obtain;
  N.ClearChildren;
  N.FKind := AKind;
  N.FValue := AValue;
end;

procedure TJson.SetAsString(const AValue: string);
begin
  SetScalar(jkString, AValue);
end;

procedure TJson.SetAsInt64(AValue: Int64);
begin
  SetScalar(jkNumber, IntToStr(AValue));
end;

procedure TJson.SetAsInteger(AValue: Integer);
begin
  SetScalar(jkNumber, IntToStr(AValue));
end;

procedure TJson.SetAsNumber(AValue: Double);
begin
  if IsNaN(AValue) or IsInfinite(AValue) then
    SetScalar(jkNull, '') // JSON has no NaN/Infinity
  else
    SetScalar(jkNumber, FloatToStr(AValue, GFmt));
end;

procedure TJson.SetAsBoolean(AValue: Boolean);
begin
  if AValue then
    SetScalar(jkBoolean, 'true')
  else
    SetScalar(jkBoolean, 'false');
end;

function TJson.SetType(AKind: TJKind): TJson;
begin
  if not(AKind in [jkObject, jkArray, jkNull]) then
    raise EJsonError.CreateFmt
      ('SetType: %s is not supported, use AsString/AsNumber/...',
      [KIND_NAMES[AKind]]);
  Obtain.BecomeContainer(AKind);
  Result := Self;
end;

function TJson.SetObject: TJson;
begin
  Result := SetType(jkObject);
end;

function TJson.SetArray: TJson;
begin
  Result := SetType(jkArray);
end;

function TJson.SetNull: TJson;
begin
  Result := SetType(jkNull);
end;

function TJson.HasKey(const AKey: string): Boolean;
var
  R, c: TJson;
begin
  Result := False;
  R := Resolve;
  if R = nil then
    Exit;
  c := R.FindChild(AKey);
  Result := (c <> nil) and (c.FKind <> jkMissing);
end;

function TJson.GetAsStrings: TStrings;
var
  R: TJson;
  i: Integer;
begin
  if FStrings = nil then
    FStrings := TStringList.Create;
  FStrings.Clear;
  R := Resolve;
  if (R <> nil) and (R.FKind = jkArray) then
    for i := 0 to R.ChildCount - 1 do
      FStrings.Add(R.ChildAt(i).GetAsString);
  Result := FStrings;
end;

procedure TJson.SetAsStrings(AValue: TStrings);
begin
  SetArray; // Knoten ist danach immer ein Array
  if AValue <> nil then
    Add(AValue);
end;

function TJson.Add: TJson;
var
  N: TJson;
begin
  N := Obtain;
  if N.FKind in [jkMissing, jkNull] then
    N.BecomeContainer(jkArray)
  else if N.FKind <> jkArray then
    raise EJsonError.CreateFmt('Add: node is %s, not an array',
      [KIND_NAMES[N.FKind]]);
  Result := N.NewChild('');
end;

function TJson.Add(AList: TStrings): TJson;
var
  i: Integer;
begin
  for i := 0 to AList.Count - 1 do
    Add(AList[i]);
  Result := Self;
end;

function TJson.Add(const AValue: string): TJson;
begin
  Result := Add; // ruft deine Original-Add auf (Obtain, Typprüfung, NewChild)
  Result.AsString := AValue;
end;

function TJson.Delete(const AKey: string): Boolean;
var
  R, c: TJson;
begin
  Result := False;
  R := Resolve;
  if R = nil then
    Exit;
  c := R.FindChild(AKey);
  if c = nil then
    Exit;
  R.FChild.Remove(c);
  c.Free;
  Result := True;
end;

function TJson.Delete(AIndex: Integer): Boolean;
var
  R, c: TJson;
begin
  Result := False;
  R := Resolve;
  if R = nil then
    Exit;
  c := R.ChildAt(AIndex);
  if c = nil then
    Exit;
  R.FChild.Remove(c);
  c.Free;
  Result := True;
end;

procedure TJson.Clear;
var
  R: TJson;
begin
  R := Resolve;
  if R = nil then
    Exit;
  R.ClearChildren;
  R.FKind := jkMissing;
  R.FValue := '';
end;

{ ---------------------------------------------------------------------------- }
{ path: Pfad mit definierberem Trenner auswerten
  { ---------------------------------------------------------------------------- }
function TJson.Path(const APath: string; const ASep: string): TJson;
var
  P, Q, Idx: Integer;
  Seg: string;
  R: TJson;
begin
  Result := Self;
  if ASep = '' then
  begin
    Result := GetByKey(APath); // kein Trenner: ganzer Text ist ein Key
    Exit;
  end;
  P := 1;
  while P <= Length(APath) do
  begin
    Q := PosEx(ASep, APath, P);
    if Q = 0 then
      Q := Length(APath) + 1;
    Seg := Copy(APath, P, Q - P);
    P := Q + Length(ASep);
    if Seg = '' then
      Continue; // führende, doppelte, abschließende Trenner ignorieren
    R := Result.Resolve;
    if (R <> nil) and (R.FKind = jkArray) and TryStrToInt(Seg, Idx) then
      Result := Result.GetByIdx(Idx) // Zahl auf einem Array: Index
    else
      Result := Result.GetByKey(Seg); // sonst Key
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TJson - parser
  { ---------------------------------------------------------------------------- }

procedure TJson.ParseValue(const S: string; var P: Integer);
var
  Str: string;
begin
  SkipWS(S, P);
  if P > Length(S) then
    ParseError('unexpected end of text', P);
  case S[P] of
    '{':
      ParseObject(S, P);
    '[':
      ParseArray(S, P);
    '"', '''':
      begin
        ParseString(S, P, Str);
        ClearChildren;
        FKind := jkString;
        FValue := Str;
      end;
    '-', '0' .. '9':
      begin
        ParseNumber(S, P, Str);
        ClearChildren;
        FKind := jkNumber;
        FValue := Str;
      end;
  else
    ParseIdent(S, P, Str);
    Str := LowerCase(Str);
    ClearChildren;
    if Str = 'true' then
    begin
      FKind := jkBoolean;
      FValue := 'true';
    end
    else if Str = 'false' then
    begin
      FKind := jkBoolean;
      FValue := 'false';
    end
    else if Str = 'null' then
    begin
      FKind := jkNull;
      FValue := '';
    end
    else
      ParseError('unexpected token "' + Str + '"', P - Length(Str));
  end;
end;

procedure TJson.ParseObject(const S: string; var P: Integer);
var
  Key: string;
  c: TJson;
begin
  BecomeContainer(jkObject);
  Inc(P); // '{'
  while True do
  begin
    SkipWS(S, P);
    if P > Length(S) then
      ParseError('unterminated object', P);
    if S[P] = '}' then
    begin
      Inc(P);
      Exit;
    end;
    if (S[P] = '"') or (S[P] = '''') then
      ParseString(S, P, Key)
    else
      ParseIdent(S, P, Key); // JS-style unquoted key
    SkipWS(S, P);
    if (P > Length(S)) or (S[P] <> ':') then
      ParseError('expected ":"', P);
    Inc(P);
    c := NewChild(Key);
    c.ParseValue(S, P);
    SkipWS(S, P);
    if P > Length(S) then
      ParseError('unterminated object', P);
    if S[P] = ',' then
      Inc(P)
    else if S[P] <> '}' then
      ParseError('expected "," or "}"', P);
  end;
end;

procedure TJson.ParseArray(const S: string; var P: Integer);
var
  c: TJson;
begin
  BecomeContainer(jkArray);
  Inc(P); // '['
  while True do
  begin
    SkipWS(S, P);
    if P > Length(S) then
      ParseError('unterminated array', P);
    if S[P] = ']' then
    begin
      Inc(P);
      Exit;
    end;
    c := NewChild('');
    c.ParseValue(S, P);
    SkipWS(S, P);
    if P > Length(S) then
      ParseError('unterminated array', P);
    if S[P] = ',' then
      Inc(P)
    else if S[P] <> ']' then
      ParseError('expected "," or "]"', P);
  end;
end;

procedure TJson.SetAsJSON(const AValue: string);
var
  Tmp: TJson;
  P: Integer;
begin
  // parse into a temporary tree first: a failure leaves the current data intact
  Tmp := TJson.Create;
  try
    P := 1;
    Tmp.ParseValue(AValue, P);
    SkipWS(AValue, P);
    if P <= Length(AValue) then
      ParseError('unexpected trailing characters', P);
    Obtain.TakeFrom(Tmp);
  finally
    Tmp.Free;
  end;
end;

function TJson.TryParse(const AJson: string): Boolean;
begin
  try
    SetAsJSON(AJson);
    Result := True;
  except
    on EJsonError do
      Result := False;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TJson - writer / files }
{ ---------------------------------------------------------------------------- }

procedure TJson.WriteTo(var B: string; var N: Integer; AHuman: Boolean;
  ALevel: Integer);
var
  i, Cnt: Integer;
  c: TJson;
  OpenCh, CloseCh: string;
begin
  case FKind of
    jkString:
      BufAddQuoted(B, N, FValue);
    jkNumber, jkBoolean:
      BufAdd(B, N, FValue);
    jkObject, jkArray:
      begin
        if FKind = jkObject then
        begin
          OpenCh := '{';
          CloseCh := '}';
        end
        else
        begin
          OpenCh := '[';
          CloseCh := ']';
        end;
        Cnt := ChildCount;
        BufAdd(B, N, OpenCh);
        for i := 0 to Cnt - 1 do
        begin
          c := TJson(FChild[i]);
          if i > 0 then
            BufAdd(B, N, ',');
          if AHuman then
            BufAdd(B, N, sLineBreak + StringOfChar(' ', (ALevel + 1) * 2));
          if FKind = jkObject then
          begin
            BufAddQuoted(B, N, c.FKey);
            if AHuman then
              BufAdd(B, N, ': ')
            else
              BufAdd(B, N, ':');
          end;
          c.WriteTo(B, N, AHuman, ALevel + 1);
        end;
        if AHuman and (Cnt > 0) then
          BufAdd(B, N, sLineBreak + StringOfChar(' ', ALevel * 2));
        BufAdd(B, N, CloseCh);
      end;
  else
    BufAdd(B, N, 'null'); // jkNull and unset children
  end;
end;

function TJson.ToString(AHuman: Boolean): string;
var
  R: TJson;
  B: string;
  N: Integer;
begin
  Result := '';
  R := Resolve;
  if (R = nil) or (R.FKind = jkMissing) then
    Exit; // nothing to serialize
  B := '';
  N := 0;
  R.WriteTo(B, N, AHuman, 0);
  SetLength(B, N);
  Result := B;
end;

procedure TJson.LoadFromFile(const AFileName: string);
var
  FS: TFileStream;
  Raw: AnsiString;
  Len: Int64;
  Txt: string;
begin
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Len := FS.Size;
    SetLength(Raw, Len);
    if Len > 0 then
      FS.ReadBuffer(Raw[1], Len);
  finally
    FS.Free;
  end;
  if (Length(Raw) >= 3) and (Raw[1] = #$EF) and (Raw[2] = #$BB) and
    (Raw[3] = #$BF) then
    System.Delete(Raw, 1, 3);
{$IFDEF UNICODE}
  Txt := UTF8ToString(Raw);
{$ELSE}
  Txt := Raw;
{$ENDIF}
  SetAsJSON(Txt);
end;

procedure TJson.SaveToFile(const AFileName: string; AHuman: Boolean);
var
  FS: TFileStream;
  Raw: AnsiString;
begin
{$IFDEF UNICODE}
  Raw := UTF8Encode(ToString(AHuman));
{$ELSE}
  Raw := ToString(AHuman);
{$ENDIF}
  FS := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(Raw) > 0 then
      FS.WriteBuffer(Raw[1], Length(Raw));
  finally
    FS.Free;
  end;
end;

function TJson.GetEnumerator: TJsonEnumerator;
begin
  Result := TJsonEnumerator.Create(Self);
end;

initialization

{$IFDEF FPC}
  GFmt := DefaultFormatSettings;
{$ELSE}
  GFmt := TFormatSettings.Create;
{$ENDIF}
GFmt.DecimalSeparator := '.';

end.
