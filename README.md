# McJsonLite

A small but elegant JSON unit for Delphi and Free Pascal with a syntax close to JavaScript.
It is a fork in the spirit of [McJSON](https://github.com/hydrobyte/McJSON),
largely compatible in use, but **without exceptions on read access**. This is a huge 
improvement, as it makes tons of typechecks unnecessary.

While most of the code is plug-in compatible, some names have been changed:
- TMcJson -> TJSon
- TJValueType -> Kind
see description below

```delphi
Json := TJson.Create;
Json.AsJSON := '{ brand: "BMW", tags: ["a","b"] }';   // unquoted keys are accepted

Json['brand'].AsString              // 'BMW'
Json['test'].AsString               // ''   (no error, nothing is created)
Json['a']['b'][3]['c'].AsInteger    // 0    (even if intermediate levels are missing)
Json['test'].Exists                 // False

Json['user']['name'].AsString := 'Foo';   // creates the path on demand
Json['list'].SetArray.Add('one');
```

## Advantages

- **No pre-checks.** A missing key or index never returns `nil` and never raises an
  exception. You get an empty "ghost node" instead
  (`Exists = False`, `AsString = ''`, `AsInteger = 0`, `AsBoolean = False`).
- **Chaining always works:** `Json['a']['b']['c']` is always safe.
- **Writing creates paths:** `Json['a']['b'].AsInteger := 5` creates `a` and `b`.
- **Less code to write:** one class `TJson`, no shorteners, no `AsObject`/`AsArray`
  casts.
- **Smaller:** about half the code of McJSON.
- **Valid JSON output:** strings are stored unescaped and escaped correctly on output.
  Input is forgiving like JS (unquoted keys, `'single'` quotes, trailing commas).

## Differences at a glance

| McJSON | McJsonLite |
|---|---|
| `TMcJsonItem` | `TJson` |
| `Add('key').AsString := ...` | `Json['key'].AsString := ...` |
| `Add('key', jitObject)` / `jitArray` | `Json['key'].SetObject` / `.SetArray` (chainable) |
| `HasKey('k')` | `HasKey('k')` or `Json['k'].Exists` |
| `S['k']`, `I['k']`, `A['k']` ... | `Json['k'].AsString` etc. |
| `Items[i]`, `Values['k']`, `Json['k']` | unchanged, plus `Json[i]` |
| `Key` | `Key` (read-only) |
| `Value` | `AsString` |
| `IsNull` | `Kind = jkNull` |
| `Check(...)`, `CheckException(...)` | `TryParse(...)` |

## What was removed

Shorteners (`S`, `I`, `D`, `B`, `O`, `A`, `N`, `J`), `At`, `Insert`, `AddPair`,
`Copy`, `Clone`, `IsEqual`, `Minify`, `CountItems`, `HasChild`, `IndexOf`, `Keys[]`,
`AsObject`, `AsArray`, `AsNull`, `ItemType`, `Load/SaveToStream`, the constructors
taking a type or an item, and `McJsonEscapeString`/`McJsonUnEscapeString` (no longer
needed). The unit does not target Delphi 7 or C++Builder.

## Real differences

**Types:** Instead of `TJItemType` + `TJValueType` there is a single `Kind`:
`jkMissing, jkNull, jkString, jkNumber, jkBoolean, jkObject, jkArray`.
`jkMissing` means the node does not exist. `null` counts as present
(`Exists = True`). A node's type changes only through `SetObject`, `SetArray`,
`SetNull`, `SetType`, or by assigning a value.

**Reading is lenient, `As...` converts:** if the type does not fit, you get the
default value (`''`, `0`, `False`), never an error. `AsString` returns the text for
numbers and booleans (`'1.5'`, `'true'`) and `''` for `null`, objects and arrays.

**Strings are unescaped:** McJSON stores the raw, escaped text, so `Value` contained
e.g. `\n` as two characters. In McJsonLite `AsString` contains the actual line break.
Escaping values yourself before assigning them is no longer necessary and would
escape twice.

**Writing can still raise exceptions** (`EJsonError`):
- a key or index is written into a node that is a scalar
  (e.g. `Json['s']['x'].AsString := 'q'` when `s` is a string),
- `Add` on a node that is not missing, `null` or an array,
- invalid text assigned to `AsJSON`. The existing data is left intact in that case.

**`Add` is different:** `Add` only appends to arrays (push). Object entries are
created by writing (`Json['k']...`). `SetObject`/`SetArray` on an existing key
**replaces** its content, whereas `Add(key, ...)` in McJSON created a duplicate.

**Duplicate keys:** the last one wins, as in JS.

**Lifetime:** only the root is freed. Node references become invalid once the node or
one of its ancestors has been replaced via `Delete`, `Clear`, `SetObject` or
`SetArray`. Not thread-safe (even reading can create ghost nodes).

## License

MIT. Derived from McJSON, © 2021–2025 HydroByte Software (MIT). The copyright
notice must be retained.
