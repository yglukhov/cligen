import macros, tables, cligen/parseopt3, strutils, os
type HelpOnly*    = object of Exception
type VersionOnly* = object of Exception
type ParseError*  = object of Exception

const positionalAuto = "<AUTO>"

proc dispatchId(name: string="", cmd: string="", rep: string=""): NimIdent =
  ## Build Nim ident for generated parser-dispatcher proc
  result = if name.len > 0: toNimIdent(name)
           elif cmd.len > 0: toNimIdent("dispatch" & cmd)  #XXX illegal chars
           else: toNimIdent("dispatch" & rep)

proc toString(c: char): string =
  ##Creates a string from char ``c``
  result = newStringOfCap(1)
  if c != '\0': result.add(c)

proc toStrLitNode(n: NimNode): NimNode =
  ##Creates a string literal node from a char literal NimNode
  result = newNimNode(nnkStrLit)
  result.strVal = toString(chr(n.intVal))

proc toStrSeq(strSeqInitializer: NimNode): seq[string] =
  result = newSeq[string]()
  for kid in strSeqInitializer[1]:
    result.add($kid)

proc containsParam(fpars: NimNode, key: string): bool =
  for declIx in 1 ..< len(fpars):           #default for result = false
    let idefs = fpars[declIx]               #Must use similar logic to..
    for i in 0 ..< len(idefs) - 3:          #..formalParamExpand because
      if $idefs[i] == key: return true      #..`suppress` is itself one of
    if $idefs[^3] == key: return true       #..the symbol lists we check.

proc formalParamExpand(fpars: NimNode, n:auto, supp: seq[string]= @[]): NimNode=
  # a,b,..,c:type [maybe=val] --> a:type, b:type, ..., c:type [maybe=val]
  result = newNimNode(nnkFormalParams)
  result.add(fpars[0])                                  # just copy ret value
  for p in supp:
    if not fpars.containsParam(p):
      error repr(n[0]) & " has no param matching `suppress` key \"" & p & "\""
  for declIx in 1 ..< len(fpars):
    let idefs = fpars[declIx]
    for i in 0 ..< len(idefs) - 3:
      if $idefs[i] notin supp:
        result.add(newIdentDefs(idefs[i], idefs[^2]))
    if $idefs[^3] notin supp:
      result.add(newIdentDefs(idefs[^3], idefs[^2], idefs[^1]))

proc formalParams(n: NimNode, suppress: seq[string]= @[]): NimNode =
  # Extract formal parameter list from the return value of .symbol.getImpl
  for kid in n:
    if kid.kind == nnkFormalParams:
      return formalParamExpand(kid, n, suppress)
  error "formalParams requires a proc argument."
  return nil                #not-reached

proc parseHelps(helps: NimNode, proNm: auto, fpars: auto): Table[string,string]=
  # Compute a table giving the help text for any parameter
  result = initTable[string, string]()
  for ph in helps:
      let p: string = (ph[1][0]).strVal
      let h: string = (ph[1][1]).strVal
      result[p] = h
      if not fpars.containsParam(p):
        error $proNm & " has no param matching `help` key \"" & p & "\""

proc parseShorts(shorts: NimNode, proNm: auto, fpars: auto): Table[string,char]=
  # Compute a table giving the user-specified short option for any parameter
  result = initTable[string, char]()
  for losh in shorts:
      let lo: string = (losh[1][0]).strVal
      let sh: char = char((losh[1][1]).intVal)
      result[lo] = sh
      if lo.len > 0 and not fpars.containsParam(lo):
        error $proNm & " has no param matching `short` key \"" & lo & "\""

proc dupBlock(fpars: NimNode, posIx: int, hlpCh: NimNode,
              userSpec: Table[string, char]): Table[string, char] =
  # Compute a table giving the short option for any long option, being
  # careful to only allow one such short option if the 1st letters of
  # two or more long options collide.
  result = initTable[string, char]()         # short option for param
  if "" in userSpec: return                  # Empty string key==>no short opts
  var used: set[char]={ chr(hlpCh.intVal) }  # used shorts; bit vector ok
  for lo, sh in userSpec:
    result[lo] = sh
    used.incl(sh)
  for i in 1 ..< len(fpars):                 # [0] is proc, not desired here
    if i == posIx: continue                  # positionals get no option char
    let parNm = $(fpars[i][0])
    if parNm.len == 1 and parNm[0] == chr(hlpCh.intVal):
      error "Error: `" & parNm & "` collides with `shortHelp`.  Use another " &
            "shortHelp='char' in `dispatch`."
    let sh = parNm[0]                        # abbreviation is 1st character
    if sh notin used and parNm notin result: # still available
      result[parNm] = sh
      used.incl(sh)
  for k, v in result:
    if v == '\0': result.del(k)

proc collectComments(buf: var string, n: NimNode, depth: int = 0) =
  if n.len > 1:
    for kid in n: collectComments(buf, kid, depth + 1)
  else:
    if n.kind == nnkCommentStmt and depth < 4:
      if n.strVal.len != 0:
        buf.add(" ")
        buf.add(n.strVal)

proc findByName(parNm: string, fpars: NimNode): int =
  result = -1
  if len(parNm) == 0: return
  for i in 1 ..< len(fpars):
    if $fpars[i][0] == parNm:
      result = i
      break
  if result == -1:
    warning("specified positional argument `" & parNm & "` not found")

proc posIxGet(positional: string, fpars: NimNode): int =
  ## Find the proc param to map to optional positional arguments of a command.
  if positional == "":
    return -1
  if positional != positionalAuto:
    result = findByName(positional, fpars)
    if result == -1:
      error("requested positional argument catcher " & positional &
            " is not in formal parameter list")
    return
  result = -1                     # No optional positional arg param yet found
  for i in 1 ..< len(fpars):
    let idef = fpars[i]           # 1st typed,non-defaulted seq; Allow override?
    if idef[1].kind != nnkEmpty and idef[2].kind == nnkEmpty and
       typeKind(getType(idef[1])) == ntySequence:
      if result != -1:            # Allow multiple seq[T]s via "--" separators?
        warning("cligen only supports one seq param for positional args; using"&
                " `" & $fpars[result][0] & "`, not `" & $fpars[i][0] & "`.  " &
                "Use `positional` parameter to `dispatch` to override this.")
      else:
        result = i

proc newParam(id: string, rhs: NimNode): NimNode =
  return newNimNode(nnkExprEqExpr).add(ident(id), rhs)

const helpTabOption*  = 0
const helpTabType*    = 1
const helpTabDefault* = 2
const helpTabDescrip* = 3
const helpTabColsDfl* = @[ helpTabOption, helpTabType,
                           helpTabDefault, helpTabDescrip ]

proc postInc*(x: var int): int =
  ## Similar to post-fix ``++`` in C languages: yield initial val, then increment
  result = x
  inc(x)

proc delItem*[T](x: var seq[T], item: T): int =
  result = find(x, item)
  if result >= 0:
    x.del(Natural(result))

type Version* = tuple[longOpt: string, output: string]

const dflUsage* = "${prelude}$command $args\n" &
                  "$doc  Options(opt-arg sep :|=|spc):\n" & "$options$sep"

type
  ClStatus* = enum clBadKey,                        ## Unknown long key
                   clBadVal,                        ## Unparsable value
                   clNonOption,                     ## Unexpected non-option
                   clMissing,                       ## Mandatory but missing
                   clParseOptErr,                   ## parseopt error
                   clOk,                            ## Option parse part ok
                   clPositional,                    ## Expected non-option
                   clHelpOnly, clVersionOnly        ## Early Exit requests

  ClParse* = tuple[paramName: string,   ## Param name/long opt key
                   unparsedVal: string, ## Unparsed val ("" for missing)
                   message: string,     ## default error message
                   status: ClStatus]    ## Parse status for param

const ClErrors* = { clBadKey, clBadVal, clNonOption, clMissing }
const ClExit*   = { clHelpOnly, clVersionOnly }
const ClNoCall* = ClErrors + ClExit

proc contains*(x: openArray[ClParse], paramName: string): bool =
  ##Test if the ``seq`` updated via ``setByParse`` contains a parameter.
  for e in x:
    if e.paramName == paramName: return true

proc contains*(x: openArray[ClParse], status: ClStatus): bool =
  ##Test if the ``seq`` updated via ``setByParse`` contains a certain status.
  for e in x:
    if e.status == status: return true

proc numOfStatus*(x: openArray[ClParse], stati: set[ClStatus]): int =
  ##Count elements in the ``setByParse seq`` with parse status in ``stati``.
  for e in x:
    if e.status in stati: inc(result)

proc next*(x: openArray[ClParse], stati: set[ClStatus], start=0): int =
  ##First index after startIx in ``setByParse seq`` w/parse status in ``stati``.
  result = -1
  for i, e in x:
    if e.status in stati: return i

include cligen/syntaxHelp

macro dispatchGen*(pro: typed{nkSym}, cmdName: string = "", doc: string = "",
 help: typed = {}, short: typed = {}, usage: string=dflUsage,
 prelude="Usage:\n  ", echoResult: bool=false, requireSeparator: bool=false,
 sepChars={'=',':'},
 opChars={'+','-','*','/','%','@',',','.','&','|','~','^','$','#','<','>','?'},
 helpTabColumnGap: int=2, helpTabMinLast: int=16, helpTabRowSep: string="",
 helpTabColumns: seq[int] = helpTabColsDfl, stopWords: seq[string] = @[],
 positional: static string = positionalAuto, suppress: seq[string] = @[],
 shortHelp = 'h', implicitDefault: seq[string] = @[], mandatoryHelp="REQUIRED",
 mandatoryOverride: seq[string] = @[], version: Version=("",""),
 noAutoEcho: bool=false, dispatchName: string = "",
 setByParse: ptr var seq[ClParse]=nil): untyped =
  ## Generate a command-line dispatcher for proc ``pro`` with extra help ``usage``.
  ## Parameters without defaults in the proc become mandatory command arguments
  ## while those with default values become command options.  Proc parameters
  ## and option keys are normalized so that command users may spell multi-word
  ## option keys flexibly as in ``--dry-Run | --dryrun``.  Each proc parameter
  ## type must have in-scope ``argParse`` and ``argHelp`` procs (``argcvt.nim``
  ## defines ``argParse/Help`` for many basic types, ``set[T]``, ``seq[T]``, etc.).
  ##
  ## ``help`` is a ``{(paramNm,str)}`` of per-param help, eg. ``{"quiet":"be quiet"}``.
  ## Very often, only these user-given help strings are needed for a decent CLI.
  ##
  ## ``short`` is a ``{(paramNm,char)}`` of per-parameter single-char option keys.
  ##
  ## Since programs can return integer exit codes (often 1-byte) to OSes, if the
  ## proc return is convertible to ``int`` that value is propagated unless
  ## ``echoResult`` is true.  However, if ``echoResult`` is true or if the
  ## result is unconvertible and ``noAutoEcho`` is false then the generated
  ## dispatcher echos the result of wrapped procs.  (Technically, dispatcher
  ## callers like ``cligenQuit`` implement this behavior.)
  ##
  ## If ``requireSeparator`` is true, both long and short options need an element
  ## of ``sepChars`` before option values (if there are any).  Any series of chars
  ## in ``opChars`` may prefix an element of ``sepChars`` as in ``parseopt3``.
  ##
  ## ``stopWords`` is a seq[string] of words beyond which ``-`` or ``--`` will no
  ## longer signify an option (like the common sole ``--`` command argument).
  ##
  ## ``helpTabColumnGap`` and ``helpTabMinLast`` control format parameters of the
  ## options help table, and ``helpTabRowSep`` ("" by default) separates rows.
  ## ``helpTabColumns`` selects columns to format and is a seq of some subset of
  ## ``{ helpTabOption, helpTabType, helpTabDefault, helpTabDescrip }``, though
  ## only the final column in a help table row auto-word-wraps.
  ##
  ## By default, ``cligen`` maps the first non-defaulted ``seq[]`` proc parameter
  ## to any non-option/positional command args.  ``positional`` selects another.
  ## Set ``positional`` to the empty string (``""``) to disable this entirely.
  ##
  ## ``suppress`` is a list of formal parameter names to NOT include in the
  ## parsing/assigning system.  Such names are effectively pinned to whatever
  ## their default values are.
  ##
  ## ``shortHelp`` is a char to use for a short option key analogue of --help.
  ##
  ## ``implicitDefault`` is a list of formal parameter names allowed to default
  ## to the Nim default value for a type, rather than becoming mandatory, even
  ## when they are missing an explicit initializer. ``mandatoryHelp`` is how the
  ## default value appears in help messages for mandatory parameters.
  ##
  ## ``mandatoryHelp`` is the default value string in help tables for required
  ## parameters.  ``mandatoryOverride`` is a list of strings indicating parameter
  ## names which override mandatory-ness of anything else.
  ##
  ## ``version`` is a ``Version`` 2-tuple ``(`longOpt for version`, `version string`)``
  ## which defines how a CLI user may dump the version of a program.  If you
  ## want to provide a short option, add a ``"version":'v'`` entry to ``short``.
  ##
  ## ``dispatchName`` is the name of a generated dispatcher, defaulting to simply
  ## ``"dispatchpro"`` where ``pro`` is the name of the proc being wrapped.
  ##
  ## ``setByParse`` is ``addr(some var seq[ClParse])``.  When provided/non-nil, this
  ## collects each parameter seen, keyed under its long/param name (i.e., parsed
  ## but not converted to native types).  Wrapped procs can inspect this or even
  ## convert args themselves to revive ``parseopt``-like iterative interpretation.
  ## ``cligen`` provides convenience procs to interpret ``setByParse``: ``contains``,
  ## ``numOfStatus`` & ``next``.  Note that ordinary Nim procs, from inside calls,
  ## do not know how params got their values (positional, keyword, defaulting).
  ## Wrapped procs accessing ``setByParse`` are inherently command-line only.  So,
  ## this ``var seq`` needing to be declared before such procs for such access is
  ## ok.  Ideally, keep important functionality Nim-callable.  ``setByParse`` may
  ## also be useful combined with the ``parseOnly`` arg of generated dispatchers.

  #XXX quote-do fails to access macro args in sub-scopes. So `help`, `cmdName`..
  #XXX need either to be used at top-level or assigned in a shadow local.
  let impl = pro.symbol.getImpl
  let fpars = formalParams(impl, toStrSeq(suppress))
  var cmtDoc: string = $doc
  if cmtDoc.len == 0:                   # allow caller to override commentDoc
    collectComments(cmtDoc, impl)
    cmtDoc = strip(cmtDoc)
  let proNm = $pro                      # Name of wrapped proc
  let cName = if len($cmdName) == 0: proNm else: $cmdName
  let disNm = dispatchId($dispatchName, cName, proNm) # Name of dispatch wrapper
  let helps = parseHelps(help, proNm, fpars)
  let posIx = posIxGet(positional, fpars) #param slot for positional cmd args|-1
  let shOpt = dupBlock(fpars, posIx, shortHelp, parseShorts(short,proNm,fpars))
  var spars = copyNimTree(fpars)        # Create shadow/safe suffixed params.
  var dpars = copyNimTree(fpars)        # Create default suffixed params.
  var mandatory = newSeq[int]()         # At the same time, build metadata on..
  let implDef = toStrSeq(implicitDefault)
  for p in implDef:
    if not fpars.containsParam(p):
      error $proNm&" has no param matching `implicitDefault` key \"" & p & "\""
  let mandOvr = toStrSeq(mandatoryOverride)
  for p in mandOvr:
   if not fpars.containsParam(p):
     error $proNm&" has no param matching `mandatoryOverride` key \"" & p & "\""
  for i in 1 ..< len(fpars):            #..non-defaulted/mandatory parameters.
    dpars[i][0] = ident($(fpars[i][0]) & "ParamDefault")   # unique suffix
    spars[i][0] = ident($(fpars[i][0]) & "ParamDispatch")  # unique suffix
    if fpars[i][2].kind == nnkEmpty:
      if i == posIx:                    # No initializer; Add @[]
        spars[posIx][2] = prefix(newNimNode(nnkBracket), "@")
      else:
        if fpars[i][1].kind == nnkEmpty:
          error("parameter `" & $(fpars[i][0]) &
                "` has neither a type nor a default value")
        if $fpars[i][0] notin implDef:
          mandatory.add(i)
  let posNoId = ident("posNo")          # positional arg number
  let keyCountId = ident("keyCount")    # positional arg number
  let docId = ident("doc")              # gen proc parameter
  let usageId = ident("usage")          # gen proc parameter
  let cmdLineId = ident("cmdline")      # gen proc parameter
  let vsnOpt = $version[0]              # Need string lits here for CL parse
  let vsnSh = if vsnOpt in shOpt: $shOpt[vsnOpt] else: ""
  let vsnStr = version[1]               # value must just work in stdout.write
  let prefixId = ident("prefix")        # local help prefix param
  let subSepId = ident("subSep")        # sub cmd help separator
  let pId = ident("p")                  # local OptParser result handle
  let allId = ident("allParams")        # local list of all parameters
  let mandId = ident("mand")            # local list of mandatory parameters
  let mandInFId = ident("mandInForce")  # mandatory-in-force flag
  let apId = ident("ap")                # ArgcvtParams
  var callIt = newNimNode(nnkCall)      # call of wrapped proc in genproc
  callIt.add(pro)
  let htColGap = helpTabColumnGap
  let htMinLst = helpTabMinLast
  let htRowSep = helpTabRowSep
  let htCols   = helpTabColumns
  let prlude   = prelude; let mandHelp = mandatoryHelp
  let shortHlp = shortHelp
  let setByParseId = ident("setByP")    # parse recording var seq
  let setByParseP = setByParse

  proc initVars(): NimNode =            # init vars & build help str
    result = newStmtList()
    let tabId = ident("tab")            # local help table var
    result.add(quote do:
      var `apId`: ArgcvtParams
      `apId`.mand = `mandHelp`
      let shortH = $(`shortHlp`)
      var `allId`: seq[string] = @[ "help", "help-syntax" ]
      var `mandId`: seq[string]
      var `mandInFId` = true
      var `tabId`: TextTab =
        @[ @[ "-"&shortH&", --help", "", "", "print this cligen-erated help" ],
           @[ "--help-syntax", "", "", "advanced: prepend, multi-val,.." ] ]
      `apId`.shortNoVal = { shortH[0] }               # argHelp(bool) updates
      `apId`.longNoVal = @[ "help", "help-syntax" ]   # argHelp(bool) appends
      let `setByParseId`: ptr seq[ClParse] = `setByParseP`)
    if vsnOpt.len > 0:
      result.add(quote do:
       var versionDflt = false
       `apId`.parNm = `vsnOpt`; `apId`.parSh = `vsnSh`; `apId`.parReq = 0
       `tabId`.add(argHelp(versionDflt, `apId`) & "print version"))
    let argStart = if mandatory.len > 0: "[required&optional-params]" else:
                                         "[optional-params]"
    let posHelp = if posIx != -1:
                    if $fpars[posIx][0] in helps: helps[$fpars[posIx][0]]
                    else:
                      let typeName = fpars[posIx][1][1].strVal
                      "[" & $(fpars[posIx][0]) & ": " & typeName & "...]"
                  else: ""
    var args = argStart & " " & posHelp
    for i in 1 ..< len(fpars):
      let idef = fpars[i]
      let sdef = spars[i]
      result.add(newNimNode(nnkVarSection).add(sdef))     #Init vars
      if i != posIx:
        result.add(newVarStmt(dpars[i][0], sdef[0]))
      callIt.add(newNimNode(nnkExprEqExpr).add(idef[0], sdef[0])) #Add to call
      if i != posIx:
        let parNm = $idef[0]
        let sh = toString(shOpt.getOrDefault(parNm))      #Add to perPar helpTab
        let defVal = sdef[0]
        let hlp =
          if parNm in helps:
            helps.getOrDefault(parNm)
          else:
            ""
        let isReq = if i in mandatory: true else: false
        result.add(quote do:
         `apId`.parNm = `parNm`; `apId`.parSh = `sh`; `apId`.parReq = `isReq`
         let descr = getDescription(`defVal`, `parNm`, `hlp`)
         `tabId`.add(argHelp(`defVal`, `apId`) & descr); `allId`.add(`parNm`) )
        if isReq:
          result.add(quote do: `mandId`.add(`parNm`))
    result.add(quote do:                  # build one large help string
      let indentDoc = addPrefix(`prefixId`, `docId`)
      `apId`.help = `usageId` % [ "prelude", `prlude`, "doc", indentDoc,
                     "command", `cName`, "args", `args`, "options",
                     addPrefix(`prefixId` & "  ",
                               alignTable(`tabId`, 2*len(`prefixId`) + 2,
                                          `htColGap`, `htMinLst`, `htRowSep`,
                                          `htCols`)),
                     "sep", `subSepId` ]
      if `apId`.help[^1] != '\n':            # ensure newline @end of help
        `apId`.help &= "\n"
      if len(`prefixId`) > 0:             # to indent help in a multicmd context
        `apId`.help = addPrefix(`prefixId`, `apId`.help))

  proc defOptCases(): NimNode =
    result = newNimNode(nnkCaseStmt).add(quote do: optionNormalize(`pId`.key))
    result.add(newNimNode(nnkOfBranch).add(
      newStrLitNode("help"), toStrLitNode(shortHlp)).add(
        quote do:
          if cast[pointer](`setByParseId`) != nil:
            `setByParseId`[].add(("help", "", `apId`.help, clHelpOnly))
            return                            #Do not try to keep parsing
          else:
            stdout.write(`apId`.help); raise newException(HelpOnly, "")))
    result.add(newNimNode(nnkOfBranch).add(
      newStrLitNode("helpsyntax")).add(
        quote do:
          if cast[pointer](`setByParseId`) != nil:
            `setByParseId`[].add(("helpsyntax", "", syntaxHelp, clHelpOnly))
            return                            #Do not try to keep parsing
          else:
            stdout.write(syntaxHelp); raise newException(HelpOnly, "")))
    if vsnOpt.len > 0:
      if vsnOpt in shOpt:                     #There is also a short version tag
        result.add(newNimNode(nnkOfBranch).add(
          newStrLitNode(vsnOpt), newStrLitNode(vsnSh)).add(
            quote do:
              if cast[pointer](`setByParseId`) != nil:
                `setByParseId`[].add((`vsnOpt`, "", `vsnStr`, clVersionOnly))
                return                        #Do not try to keep parsing
              else:
                stdout.write(`vsnStr`,"\n");raise newException(VersionOnly,"")))
      else:                                   #There is only a long version tag
        result.add(newNimNode(nnkOfBranch).add(newStrLitNode(vsnOpt)).add(
            quote do:
              if cast[pointer](`setByParseId`) != nil:
                `setByParseId`[].add((`vsnOpt`, "", `vsnStr`, clVersionOnly))
                return                        #Do not try to keep parsing
              else:
                stdout.write(`vsnStr`,"\n");raise newException(VersionOnly,"")))
    for i in 1 ..< len(fpars):                # build per-param case clauses
      if i == posIx: continue                 # skip variable len positionals
      let parNm  = $fpars[i][0]
      let lopt   = optionNormalize(parNm)
      let spar   = spars[i][0]
      let dpar   = dpars[i][0]
      var maybeMandInForce = newNimNode(nnkEmpty)
      if `parNm` in `mandOvr`:
        maybeMandInForce = quote do:
          `mandInFId` = false
      let apCall = quote do:
        `apId`.key = `pId`.key
        `apId`.val = `pId`.val
        `apId`.sep = `pId`.sep
        `apId`.parNm = `parNm`
        `keyCountId`.inc(`parNm`)
        `apId`.parCount = `keyCountId`[`parNm`]
        if cast[pointer](`setByParseId`) != nil:
          if argParse(`spar`, `dpar`, `apId`):
            `setByParseId`[].add((`parNm`,`pId`.val, "", clOk))
          else:
            `setByParseId`[].add((`parNm`,`pId`.val,
                                 "Cannot parse arg to " & `apId`.key, clBadVal))
        else:
          if not argParse(`spar`, `dpar`, `apId`):
            stderr.write `apId`.msg
            raise newException(ParseError, "Cannot parse arg to " & `apId`.key)
        discard delItem(`mandId`, `parNm`)
        `maybeMandInForce`
      if parNm in shOpt and lopt.len > 1:     # both a long and short option
        let parShOpt = $shOpt.getOrDefault(parNm)
        result.add(newNimNode(nnkOfBranch).add(
          newStrLitNode(lopt), newStrLitNode(parShOpt)).add(apCall))
      else:                                   # only a long option
        result.add(newNimNode(nnkOfBranch).add(newStrLitNode(lopt)).add(apCall))
    result.add(newNimNode(nnkElse).add(quote do:
      var mb, k: string
      k = "short"
      if `pId`.kind == cmdLongOption:
        k = "long"
        var idNorm: seq[string]
        for id in allParams: idNorm.add(optionNormalize(id))  #Use `normalize`?
        let sugg = suggestions(optionNormalize(`pId`.key), idNorm, allParams)
        if sugg.len > 0:
          mb &= "Maybe you meant one of:\n\t" & join(sugg, " ") & "\n\n"
      let msg = ("Unknown " & k & " option: \"" & `pId`.key & "\"\n\n" &
                 mb & "Run with --help for full usage.\n")
      if cast[pointer](`setByParseId`) != nil:
        `setByParseId`[].add((`piD`.key, `pId`.val, msg, clBadKey))
      else:
        stderr.write(msg)
        raise newException(ParseError, "Unknown option")))

  proc defNonOpt(): NimNode =
    result = newStmtList()
    if posIx != -1:                           # code to parse non-option args
      result.add(newNimNode(nnkCaseStmt).add(quote do: postInc(`posNoId`)))
      let posId = spars[posIx][0]
      let tmpId = ident("tmp" & $posId)
      result[0].add(newNimNode(nnkElse).add(quote do:
        var rewind = false                  #Ugly machinery is so tmp=pos[0]..
        if len(`posId`) == 0:               #..type inference works.
          `posId`.setLen(1)
          rewind = true
        var `tmpId` = `posId`[0]
        `apId`.key = "positional $" & $`posNoId`
        `apId`.val = `pId`.key
        `apId`.sep = "="
        `apId`.parNm = `apId`.key
        `apId`.parCount = 1
        let msg = "Cannot parse " & `apId`.key
        if cast[pointer](`setByParseId`) != nil:
          if argParse(`tmpId`,`tmpId`,`apId`):
            `setByParseId`[].add((`apId`.key, `apId`.val, "", clPositional))
          else:
            `setByParseId`[].add((`apId`.key, `apId`.val, msg, clBadVal))
        else:
          if not argParse(`tmpId`, `tmpId`, `apId`):
            stderr.write `apId`.msg
            raise newException(ParseError, msg)
        if rewind: `posId`.setLen(0)
        `posId`.add(`tmpId`)))
    else:
      result.add(quote do:
        let msg = "Unexpected non-option " & $`pId`
        if cast[pointer](`setByParseId`) != nil:
          `setByParseId`[].add((`apId`.key, `pId`.val, msg, clNonOption))
        else:
          stderr.write(`proNm`&" does not expect non-option arguments.  Got\n" &
                       $`pId` & "\nRun with --help for full usage.\n")
          raise newException(ParseError, msg))

  let iniVar=initVars(); let optCases=defOptCases(); let nonOpt=defNonOpt()
  let retType=fpars[0]
  result = quote do:
    from os               import commandLineParams
    from cligen/argcvt    import ArgcvtParams, argParse, argHelp, getDescription
    from cligen/textUt    import addPrefix, TextTab, alignTable, suggestions
    from cligen/parseopt3 import initOptParser, next, cmdEnd, cmdLongOption,
                                 cmdShortOption, optionNormalize
    import tables, strutils # import join, `%`
    proc `disNm`(`cmdLineId`: seq[string] = mergeParams(@[ `cName` ]),
                 `docId`: string = `cmtDoc`, `usageId`: string = `usage`,
                 `prefixId`="", `subSepId`="", parseOnly=false): `retType` =
      {.push hint[XDeclaredButNotUsed]: off.}
      `iniVar`
      proc parser(args=`cmdLineId`) =
        var `posNoId` = 0
        var `keyCountId` = initCountTable[string]()
        var `pId` = initOptParser(args, `apId`.shortNoVal, `apId`.longNoVal,
                                  `requireSeparator`, `sepChars`, `opChars`,
                                  `stopWords`)
        while true:
          next(`pId`)
          if `pId`.kind == cmdEnd: break
          if `pId`.kind == cmdError:
            if cast[pointer](`setByParseId`) != nil:
              `setByParseId`[].add(("", "", `pId`.message, clParseOptErr))
            if not parseOnly:
              stderr.write(`pId`.message, "\n")
            break
          case `pId`.kind
            of cmdLongOption, cmdShortOption:
              `optCases`
            else:
              `nonOpt`
      {.pop.}
      parser()
      if `mandId`.len > 0 and `mandInFId`:
        if cast[pointer](`setByParseId`) != nil:
          for m in `mandId`:
            `setByParseId`[].add((m, "", "Missing " & m, clMissing))
        else:
          stderr.write "Missing these required parameters:\n"
          for m in `mandId`: stderr.write "  ", m, "\n"
          stderr.write "Run command with --help for more details.\n"
          raise newException(ParseError, "Missing one/some mandatory args")
      if parseOnly or (cast[pointer](`setByParseId`) != nil and
          `setByParseId`[].numOfStatus(ClNoCall) > 0):
        return
      `callIt`
  when defined(printDispatch): echo repr(result)  # maybe print generated code

template cligenQuit*(p: untyped, noAutoEcho: bool=false): auto =
  when compiles(int(p)):                      #Can convert to int
    try: quit(int(p))
    except HelpOnly, VersionOnly: quit(0)
    except ParseError: quit(1)
  elif not noAutoEcho and compiles(echo p):   #autoEcho && have `$`
    try: echo p; quit(0)
    except HelpOnly, VersionOnly: quit(0)
    except ParseError: quit(1)
  elif compiles(type(p)):                     #no convert to int,str but typed
    try: discard p; quit(0)
    except HelpOnly, VersionOnly: quit(0)
    except ParseError: quit(1)
  else:                                       #void return type
    try: p; quit(0)
    except HelpOnly, VersionOnly: quit(0)
    except ParseError: quit(1)

template cligenHelp*(p: untyped, dashHelp: untyped, sep: untyped): auto =
  when compiles(type(p())):
    try: discard p(dashHelp, prefix="  ", subSep=sep)
    except HelpOnly: discard
  else:
    try: p(dashHelp, prefix="  ", subSep=sep)
    except HelpOnly: discard

macro dispatchAux*(dispatchName: string, cmdName: string, pro: typed{nkSym},
                   noAutoEcho: bool, echoResult: bool): untyped =
  result = newStmtList()
  let disNm = dispatchId($dispatchName, $cmdName, $pro)
  if echoResult.boolVal:
    result.add(quote do:                      #CLI author requests echo
      try: echo `disNm`(); quit(0)
      except HelpOnly, VersionOnly: quit(0)
      except ParseError: quit(1))
  else:
    result.add(quote do:
      cligenQuit(`disNm`(), `noAutoEcho`))

template dispatch*(pro: typed{nkSym}, cmdName: string = "", doc: string = "",
 help: typed = {}, short: typed = {}, usage: string=dflUsage,
 prelude="Usage:\n  ", echoResult: bool=false, requireSeparator: bool=false,
 sepChars={'=',':'},
 opChars={'+','-','*','/','%','@',',','.','&','|','~','^','$','#','<','>','?'},
 helpTabColumnGap: int=2, helpTabMinLast: int=16, helpTabRowSep: string="",
 helpTabColumns = helpTabColsDfl, stopWords: seq[string] = @[],
 positional = positionalAuto, suppress: seq[string] = @[],
 shortHelp = 'h', implicitDefault: seq[string] = @[], mandatoryHelp="REQUIRED",
 mandatoryOverride: seq[string] = @[], version: Version=("",""),
 noAutoEcho: bool=false, dispatchName: string = ""): untyped =
  ## A convenience wrapper to both generate a command-line dispatcher and then
  ## call the dispatcher & exit; Usage is the same as the ``dispatchGen`` macro.
  dispatchGen(
    pro, cmdName, doc, help, short, usage, prelude, echoResult,
      requireSeparator, sepChars, opChars, helpTabColumnGap, helpTabMinLast,
      helpTabRowSep, helpTabColumns, stopWords, positional, suppress, shortHelp,
      implicitDefault, mandatoryHelp, mandatoryOverride, version, noAutoEcho,
      dispatchName)
  dispatchAux(dispatchName, cmdName, pro, noAutoEcho, echoResult)

proc subCmdName(node: NimNode): string =
  ## Get last `cmdName` argument, if any, in bracket expression, or name of 1st
  ## element of bracket if none given, unless that name is module-qualified.
  for child in node:
    if child.kind == nnkExprEqExpr and eqIdent(child[0], "cmdName"):
      result = $child[1]
  if result == "":
    if '.' in repr(node):
      error "qualified symbol " & repr(node) & " must manually set `cmdName`."
    else:
      result = $node[0]

proc dispatchName(node: NimNode): string =
  ## Get last dispatchName argument, if any, in bracket expression, or return
  ## "dispatch & subCmdName(node)" if none.
  result = "dispatch" & subCmdName(node)  #XXX strip illegal chars
  for child in node:
    if child.kind == nnkExprEqExpr and eqIdent(child[0], "dispatchName"):
      result = $child[1]

proc subCmdEchoRes(node: NimNode): bool =
  ##Get last echoResult value, if any, in bracket expression
  result = false
  for child in node:
    if child.kind == nnkExprEqExpr and eqIdent(child[0], "echoResult"):
      return true

proc subCmdNoAutoEc(node: NimNode): bool =
  ##Get last noAutoEcho value, if any, in bracket expression
  result = false
  for child in node:
    if child.kind == nnkExprEqExpr and eqIdent(child[0], "noAutoEcho"):
      return true

var cligenVersion* = ""

template unknownSubcommand*(cmd: string) =
  stderr.write "Unknown subcommand \"" & cmd & "\".  "
  let sugg = suggestions(cmd, subCmds, subCmds)
  if sugg.len > 0:
    stderr.write "Maybe you meant one of:\n\t" & join(sugg, " ") & "\n\n"
  else:
    stderr.write "It is not similar to defined subcommands.\n\n"
  stderr.write "Run again with subcommand \"help\" to get detailed usage.\n"

#Would be nice to grab first terminalWidth-maxSubCmdLen-4 chars from each cmd's
#doc dispatchGen param (defaulting to doc comment) for a one line per cmd table.
template topLevelHelp*(srcBase: auto, subCmdsId: auto): string = """

  $1 {CMD}  [sub-command options & parameters]

where {CMD} is one of:

  $2

$1 {-h|--help} or with no args at all prints this message.
Run "$1 {help CMD|CMD --help}" to see help for just CMD.
Run "$1 help" to get *comprehensive* help.$3""" % [ srcBase,
  join(subCmdsId, "\n  "),
  (if cligenVersion.len > 0: "\nTop-level --version also available" else: "") ]

macro dispatchMulti*(procBrackets: varargs[untyped]): untyped =
  ## A convenience wrapper to generate a multi-command dispatcher, then call the
  ## dispatcher & quit; ``procBrackets`` is arg lists for ``dispatchGen``, eg.,
  ## ``dispatchMulti([ foo, short={"dryRun": "n"} ], [ bar, doc="Um" ])``.
  result = newStmtList()
  let subCmdsId = ident("subCmds")
  result.add(quote do:
    var `subCmdsId`: seq[string] = @[ "help" ])
  for p in procBrackets:
    var c = newCall("dispatchGen")
    copyChildrenTo(p, c)
    c.add(newParam("prelude", newStrLitNode("")))
    result.add(c)
    result.add(newCall("add", subCmdsId, newStrLitNode(subCmdName(p))))
  let fileParen = lineinfo(procBrackets)  # Infer multi-cmd name from lineinfo
  let slash = if rfind(fileParen, "/") < 0: 0 else: rfind(fileParen, "/") + 1
  let paren = rfind(fileParen, ".nim(") - 1
  let srcBase = newStrLitNode(if paren < 0: "??" else: fileParen[slash..paren])
  let arg0Id = ident("arg0")
  let restId = ident("rest")
  let dashHelpId = ident("dashHelp")
  let multiId = ident("multi")
  let disSubcmdId = ident("dispatchSubcmd")
  var multiDef = newStmtList()
  multiDef.add(quote do:
    import os
    proc `multiId`(subCmd: seq[string]) =
      {.push hint[XDeclaredButNotUsed]: off.}
      let n = subCmd.len
      let `arg0Id` = if n > 0: subCmd[0] else: ""
      let `restId`: seq[string] = if n > 1: subCmd[1..<n] else: @[ ])
  var cases = multiDef[0][1][^1].add(newNimNode(nnkCaseStmt).add(arg0Id))
  var helpDump = newStmtList()
  var cnt = 0
  for p in procBrackets:
    inc(cnt)
    let sCmdNmS = subCmdName(p)
    let disNm = dispatchId(dispatchName(p), sCmdNmS, "")
    let sCmdNm = newStrLitNode(sCmdNmS)
    let sCmdEcR = subCmdEchoRes(p)
    let sCmdAuEc = not subCmdNoAutoEc(p)
    let nm0 = $srcBase
    let qnm = quote do: @[ `nm0`, `sCmdNm` ]    #qualified name
    if sCmdEcR:                                 #CLI author requests echo
      cases[^1].add(newNimNode(nnkOfBranch).add(sCmdNm).add(quote do:
        try: echo `disNm`(mergeParams(`qnm`, `restId`)); quit(0)
        except HelpOnly, VersionOnly: quit(0)
        except ParseError: quit(1)))
    else:
      cases[^1].add(newNimNode(nnkOfBranch).add(sCmdNm).add(quote do:
        when compiles(int(`disNm`())):          #Can convert to int
          try: quit(int(`disNm`(mergeParams(`qnm`, `restId`))))
          except HelpOnly, VersionOnly: quit(0)
          except ParseError: quit(1)
        elif bool(`sCmdAuEc`) and compiles(echo `disNm`()):  #autoEc && have `$`
          try: echo `disNm`(mergeParams(`qnm`, `restId`)); quit(0)
          except HelpOnly, VersionOnly: quit(0)
          except ParseError: quit(1)
        elif compiles(type(`disNm`())):         #no convert to int,str but typed
          try: discard `disNm`(mergeParams(`qnm`, `restId`)); quit(0)
          except HelpOnly, VersionOnly: quit(0)
          except ParseError: quit(1)
        else:                                   #void return type
          try: `disNm`(mergeParams(`qnm`, `restId`)); quit(0)
          except HelpOnly, VersionOnly: quit(0)
          except ParseError: quit(1)))
    let sep = if cnt < len(procBrackets): "\n" else: ""
    helpDump.add(quote do:
      cligenHelp(`disNm`, `dashHelpId`, `sep`))
  cases[^1].add(newNimNode(nnkElse).add(quote do:
    if `arg0Id` == "":
      echo "Usage:\n  ", topLevelHelp(`srcBase`, `subCmdsId`)
    elif `arg0Id` == "help":
      echo ("This is a multiple-dispatch command.  Top-level " &
            "--help/--help-syntax\nis also available.  Usage is like:\n" &
            "    $1 subcommand [subcommand-opts & args]\n" &
            "where subcommand syntaxes are as follows:\n") % [ `srcBase` ]
      let `dashHelpId` = @[ "--help" ]
      `helpDump`
    else:
      unknownSubcommand(`arg0Id`)))
  result.add(multiDef)
  let vsnTree = newTree(nnkTupleConstr, newStrLitNode("version"),
                                        newIdentNode("cligenVersion"))
  result.add(newCall("dispatchGen", multiId, newParam("stopWords", subCmdsId),
                     newParam("dispatchName", newStrLitNode("dispatchSubcmd")),
                     newParam("version", vsnTree),
                     newParam("cmdName", srcBase), newParam("usage", quote do:
    "${prelude}" & topLevelHelp(`srcBase`, `subCmdsId`))))
  result.add(quote do:
    #This is NOT mergeParams because we want typo suggestions for subcmd (with
    #options) based only on a CL user's actual command line entry.  Other srcs
    #are on their own.  This could be trouble if anyone wants commandLineParams
    #to NOT be the suffix of mergeParams, but we could also add a define switch.
    let ps = cast[seq[string]](commandLineParams())
    if ps.len>0 and (ps[0].len>0 and ps[0][0] != '-') and ps[0] notin subCmds:
      unknownSubcommand(ps[0])
    elif ps.len == 2 and ps[0] == "help":
      if ps[1] in subCmds: cligenQuit(`disSubcmdId`(@[ ps[1], "--help" ]))
      else: unknownSubcommand(ps[1])
    else:
      cligenQuit(`disSubcmdId`()))
  when defined(printMultiDisp): echo repr(result)  # maybe print generated code

proc mergeParams*(cmdNames: seq[string],
                  cmdLine=commandLineParams()): seq[string] =
  ##This is a pass-through parameter merge to provide a hook for CLI authors to
  ##create the ``seq[string]`` to be parsed from any run-time sources (likely
  ##based on ``cmdNames``) that they would like.  In a single ``dispatch``
  ##context, ``cmdNames[0]`` is the ``cmdName`` while in a ``dispatchMulti
  ##``context it is ``@[ <mainCommand>, <subCommand> ]``.
  cmdLine
