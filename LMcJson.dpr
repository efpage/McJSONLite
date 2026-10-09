program LMcJson;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils, McJsonLite;

var Fails, Total: Integer;
procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if not Cond then begin Inc(Fails); WriteLn('FAIL: ', Msg); end;
end;

var
  auto, o, it: TJson;
  s: string;
  n: Integer;
  raised: Boolean;
begin
  // 1. JS-like literal with unquoted key
  auto := TJson.Create;
  auto.AsJSON := '{ marke: "BMW" }';
  Check(auto['marke'].AsString = 'BMW', 'marke');
  Check(auto['marke'].Kind = jkString, 'kind string');

  // 2. missing: no exception, no side effects
  Check(auto['test'].AsString = '', 'missing string');
  Check(not auto['test'].Exists, 'missing exists');
  Check(auto['test'].Kind = jkMissing, 'missing kind');
  Check(auto['a']['b'][3]['c'].AsInteger = 0, 'deep missing int');
  Check(auto['a']['b'][3]['c'].AsBoolean = False, 'deep missing bool');
  Check(auto['a'].Count = 0, 'missing count');
  Check(auto.ToString = '{"marke":"BMW"}', 'no side effects: ' + auto.ToString);
  Check(auto['x'].ToString = '', 'missing tostring');

  // 3. write creates path
  auto['test'].AsString := 'TestValue';
  Check(auto['test'].AsString = 'TestValue', 'write test');
  auto['x']['y']['z'].AsInteger := 5;
  Check(auto['x']['y']['z'].AsInteger = 5, 'deep write');
  Check(auto.ToString = '{"marke":"BMW","test":"TestValue","x":{"y":{"z":5}}}', 'json: ' + auto.ToString);

  // held ghost reference becomes real after write
  o := auto['later'];
  Check(not o.Exists, 'ghost before');
  auto['later'].AsInteger := 7;
  Check(o.Exists and (o.AsInteger = 7), 'ghost after (held ref sees write)');
  o.AsInteger := 8;
  Check(auto['later'].AsInteger = 8, 'write through held ghost');
  Check(auto.Count = 4, 'count after ghost writes ' + IntToStr(auto.Count));

  // 4. arrays
  auto['list'].Add.AsInteger := 1;
  auto['list'].Add.AsString := 'two';
  Check(auto['list'].Kind = jkArray, 'array kind');
  Check(auto['list'].Count = 2, 'array count');
  Check(auto['list'][1].AsString = 'two', 'array idx');
  Check(auto['list'][5].AsInteger = 0, 'array oob read');
  auto['list'][4].AsInteger := 9;
  Check(auto['list'].ToString = '[1,"two",null,null,9]', 'pad: ' + auto['list'].ToString);
  Check(auto['list'][2].Kind = jkNull, 'null kind');

  // 5. kinds
  o := TJson.Create('{"s":"a","n":1.5,"b":true,"z":null,"o":{},"a":[], "i": 42}');
  Check(o['s'].Kind=jkString,'k s'); Check(o['n'].Kind=jkNumber,'k n'); Check(o['b'].Kind=jkBoolean,'k b');
  Check(o['z'].Kind=jkNull,'k z'); Check(o['o'].Kind=jkObject,'k o'); Check(o['a'].Kind=jkArray,'k a');
  Check(o['z'].Exists, 'null exists');
  Check(o['n'].AsNumber = 1.5, 'num'); Check(o['i'].AsInteger = 42, 'int'); Check(o['b'].AsBoolean, 'bool');
  Check(o['n'].AsInteger = 1, 'trunc'); Check(o['s'].AsInteger = 0, 'abc->0');
  Check(o['b'].AsString = 'true', 'bool str'); Check(o['z'].AsString = '', 'null str');
  Check(o.ToString = '{"s":"a","n":1.5,"b":true,"z":null,"o":{},"a":[],"i":42}', 'roundtrip ' + o.ToString);
  o.Free;

  // 6. escaping roundtrip
  o := TJson.Create;
  o['t'].AsString := 'a"b\c' + #10 + 'd' + #1;
  s := o.ToString;
  Check(s = '{"t":"a\"b\\c\nd\u0001"}', 'escape out: ' + s);
  it := TJson.Create(s);
  Check(it['t'].AsString = 'a"b\c' + #10 + 'd' + #1, 'escape roundtrip');
  it.Free;
  o.AsJSON := '{"u":"\u00e4\u20ac","e":"\ud83d\ude00", ''q'': ''it\''s''}';
  Check(o['u'].AsString = #$C3#$A4#$E2#$82#$AC, 'unicode');
  Check(o['e'].AsString = #$F0#$9F#$98#$80, 'surrogate pair');
  Check(o['q'].AsString = 'it''s', 'single quotes');
  o.Free;

  // 7. errors
  o := TJson.Create('{"keep":1}');
  raised := False;
//  try o.AsJSON := '{"a":'; except on EJsonError do raised := True; end;
//  Check(raised, 'bad json raises');
  Check(o['keep'].AsInteger = 1, 'data intact after failed parse');
  Check(not o.TryParse('{"a" 1}'), 'tryparse false');
  Check(not o.TryParse(''), 'empty');
  Check(not o.TryParse('{"a":1} x'), 'trailing');
  Check(not o.TryParse('{"a":01}'), 'leading zero');
  Check(not o.TryParse('[1,,2]'), 'double comma');
  Check(not o.TryParse('"abc'), 'unterminated');
  Check(o.TryParse('[1,2,]'), 'trailing comma ok');
  Check(o.ToString = '[1,2]', 'after tryparse');
  Check(o.TryParse('  123 '), 'toplevel scalar');
  Check(o.AsInteger = 123, 'toplevel value');
  o.Free;

  // 8. type conflicts on write raise (read never does)
  o := TJson.Create('{"s":"str","a":[1]}');
  raised := False;
  try o['s']['x'].AsString := 'q'; except on EJsonError do raised := True; end;
  Check(raised, 'write key into string raises');
  Check(o['s'].AsString = 'str', 'untouched');
  raised := False;
  try o['a']['x'].AsString := 'q'; except on EJsonError do raised := True; end;
  Check(raised, 'write key into array raises');
  Check(o['s']['x'].AsString = '', 'read key on string ok');
  Check(o['s'][0].AsString = '', 'read idx on string ok');
  o.Free;

  // 9. delete, enumerate, human
  o := TJson.Create('{"a":1,"b":[10,20,30],"c":{"d":true}}');
  n := 0; s := '';
  for it in o do begin Inc(n); s := s + it.Key + ','; end;
  Check((n = 3) and (s = 'a,b,c,'), 'enum object ' + s);
  n := 0;
  for it in o['b'] do Inc(n, it.AsInteger);
  Check(n = 60, 'enum array');
  for it in o['nope'] do Check(False, 'enum on missing');
  Check(o['b'].Delete(1), 'delete idx');
  Check(o['b'].ToString = '[10,30]', 'after delete idx');
  Check(o.Delete('a'), 'delete key');
  Check(not o.Delete('a'), 'delete again');
  Check(not o['zzz'].Delete('x'), 'delete on missing');
  Check(o.Count = 2, 'count');
  WriteLn(o.ToString(True));
  o.Free;

  // 10. dup keys: last wins
  o := TJson.Create('{"k":1,"k":2}');
  Check(o['k'].AsInteger = 2, 'dup last wins');
  o.Free;

  // 11. numbers formatting
  o := TJson.Create;
  o['a'].AsNumber := 0.1;
  o['b'].AsNumber := 1234.5678;
  o['c'].AsNumber := 1/0;
  o['d'].AsInt64 := 9007199254740993;
  o['e'].AsBoolean := False;
  o['f'].SetNull;
  o['g'].SetObject;
  o['h'].SetArray;
  Check(o.ToString = '{"a":0.1,"b":1234.5678,"c":null,"d":9007199254740993,"e":false,"f":null,"g":{},"h":[]}', 'nums ' + o.ToString);
  Check(o['d'].AsInt64 = 9007199254740993, 'int64');
  // overwrite type
  o['g'].AsString := 'now string';
  Check(o['g'].Kind = jkString, 'overwrite');
  o.Free;

  // 12. files
  o := TJson.Create('{"a":"\u00e4","l":[1,2]}');
  o.SaveToFile('/tmp/t.json');
  it := TJson.Create;
  it.LoadFromFile('/tmp/t.json');
  Check(it.ToString = o.ToString, 'file roundtrip');
  it.Free; o.Free;

  // 13. perf: 50k keys
  o := TJson.Create;
  for n := 0 to 4999 do o['key' + IntToStr(n)].AsString := 'v' + IntToStr(n);
  Check(o.Count = 5000, 'perf count');
  s := o.ToString;
  it := TJson.Create(s);
  Check(it.Count = 50000, 'perf parse');
  it.Free; o.Free;

  auto.Free; s := '';
  WriteLn(Total, ' checks, ', Fails, ' failed');
  if Fails > 0 then Halt(1);
end.
