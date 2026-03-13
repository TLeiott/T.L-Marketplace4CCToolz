---
name: TLA-develop
description: "Fully autonomous scheduler-managed single-task pipeline with read-only planning, queueing, and wave-safe auto-commit."
argument-hint: [task description]
disable-model-invocation: true
---

# /TLA-develop -- Vollautonome Geplante Einzel-Implementierungs-Pipeline

CRITICAL: Du bist Launcher UND read-only Planer. Du implementierst NICHTS selbst.
Vor dem Start darfst du read-only Kontext sammeln, um Konfliktrisiken fuer diesen EINEN Task zu bestimmen.
Erlaubt vor dem Pipeline-Start: Read, Glob, Grep, Bash.
Verboten vor dem Pipeline-Start: Edit, Write in Repo-Dateien, Commits, Builds ausser dem Usage-Gate-Probe.
KEIN User-Input nach dem Start. Alles laeuft automatisch bis zum finalen Ergebnis.
AUSNAHME: Eine einzige Rueckfrage VOR dem Start ist erlaubt, wenn weder Statusline noch Usage-Cache fuer den 5h-Gate verfuegbar sind.

## STEP 1 -- VALIDATE

Pruefe mit dem Bash-Tool (ein einziger Aufruf):
- `git rev-parse --is-inside-work-tree` -> muss `true` sein
- `git status --porcelain` -> muss leer sein

Falls nicht erfuellt: Nutzer informieren, abbrechen.

## STEP 2 -- SOLUTION FINDEN

Glob nach `*.sln` und `*.slnx` im aktuellen Verzeichnis und bis zu 2 Elternverzeichnissen.
- Mehrere gefunden -> Nutzer fragen welche
- Keine gefunden -> Nutzer informieren, abbrechen

## STEP 3 -- WINDOWS TEMP + DATEIEN

Ermittle zuerst den Windows-TEMP-Pfad und eine GUID (Bash-Tool, ein Aufruf):
    WIN_TEMP=$(powershell.exe -NoProfile -Command '$env:TEMP' | tr -d '\r')
    LOCAL_ID=$(powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString('N')" | tr -d '\r')
    DIR="$WIN_TEMP/claude-develop"
    mkdir -p "$DIR"

Merke:
- `PROMPT_FILE="$DIR/prompt-$LOCAL_ID.md"`
- `PLAN_FILE="$DIR/plan-$LOCAL_ID.json"`
- `RESULT_FILE="$DIR/result-$LOCAL_ID.json"`
- `SUBMIT_FILE="$DIR/submit-$LOCAL_ID.json"`

## STEP 4 -- SCRIPT FINDEN

Finde das Scheduler-Skript (Bash-Tool, ein Aufruf):
    SCRIPT=$(find "$HOME/.claude/plugins/marketplaces" -path "*/T.L-AutoDevelop/scripts/scheduler.ps1" -print -quit 2>/dev/null)
    if [ -z "$SCRIPT" ]; then
      SCRIPT=$(find "$HOME/.claude/plugins/cache" -path "*/T-L-AutoDevelop/*/scripts/scheduler.ps1" -print -quit 2>/dev/null)
    fi
    if [ -z "$SCRIPT" ]; then echo "ERROR: scheduler.ps1 nicht gefunden"; exit 1; fi
    GATE_SCRIPT="$(dirname "$SCRIPT")/claude-usage-gate.ps1"

## STEP 5 -- PROMPT SCHREIBEN

Schreibe den Prompt (Bash-Tool, ein Aufruf):
    cat > "$PROMPT_FILE" << 'PROMPT_EOF'
    ## Task
    $ARGUMENTS

    ## Solution
    <absoluter Pfad zur .sln/.slnx>
    PROMPT_EOF

## STEP 6 -- REPO-KONTEXT INVENTAR + TASK-KONTEXTPASS (READ-ONLY)

Baue einen kompakten read-only Repo-Ueberblick:
- Solution-Verzeichnis
- relevante Projekte (`*.csproj`)
- Top-Level Module/Ordner unterhalb der Solution, ohne `bin`, `obj`, `.git`, `.vs`, `node_modules`, `packages`
- gemeinsame Konfigurationsdateien wie `Directory.Build.*`, `Directory.Packages.props`, `global.json`, `nuget.config`, `appsettings*.json`, `*.props`, `*.targets`
- `CLAUDE.md`, falls vorhanden

Analysiere read-only, welche Dateien/Bereiche voraussichtlich betroffen sind. Nutze Read/Glob/Grep und den Repo-Ueberblick.

Du MUSST einen Datensatz bilden mit:
- `taskText`
- `taskClassGuess`
- `likelyAreas`
- `likelyFiles`
- `searchPatterns`
- `dependencyHints`
- `conflictRisk` = `LOW | MEDIUM | HIGH`
- `confidence` = `HIGH | MEDIUM | LOW`
- `rationale`

Heuristik:
- Bevorzuge konkrete Dateien ueber breite Module.
- Wenn du nur ein gemeinsames Modul, Projekt oder Konfigurationsdateien eingrenzen kannst, markiere das konservativ als `MEDIUM` oder `HIGH`.
- Wenn die Aufgabe auf gemeinsame Vertraege, APIs, DTOs, Schemas, Projektdateien oder globale Config zielt, behandle sie als breit.
- Wenn du Disjunktheit nicht belastbar nachweisen kannst, plane konservativ.

Schreibe diesen Datensatz als JSON nach `$PLAN_FILE` (Bash-Tool, ein Aufruf).

## STEP 7 -- 5H-USAGE-GATE PREFLIGHT

Falls `GATE_SCRIPT` existiert:
1. Fuehre SOFORT einen Probe-Check aus:

       START_GATE_JSON="$DIR/usage-$LOCAL_ID-start.json"
       powershell.exe -NoProfile -ExecutionPolicy Bypass \
         -File "$(cygpath -w "$GATE_SCRIPT")" \
         -Mode probe \
         -ThresholdPercent 90 > "$(cygpath -w "$START_GATE_JSON")"

2. Lies `START_GATE_JSON` mit dem Read-Tool und parse das JSON.
3. Wenn `processStatus == "fatal"`: fatalen Fehler zeigen, abbrechen.
4. Wenn `ok=true`:
   - `source`, `fiveHourUtilization`, `sevenDayUtilization`, `fiveHourResetAt` kurz anzeigen
   - klar dazusagen: NUR `fiveHourUtilization` blockiert neue Starts; `sevenDayUtilization` ist reine Info
   - `usageGateDisabled=false`
5. Wenn `processStatus != "fatal"` UND `ok=false`:
   - `errors` kurz zeigen
   - dem Nutzer GENAU EINMAL vor dem Start die Rueckfrage stellen: "Statusline und Usage-Cache sind nicht verfuegbar. Soll die 5h-Usage fuer diesen Task ignoriert werden?"
   - Bei Nein: abbrechen
   - Bei Ja: `usageGateDisabled=true`

Falls `GATE_SCRIPT` NICHT existiert:
- dem Nutzer GENAU EINMAL vor dem Start die Rueckfrage stellen: "Statusline und Usage-Cache sind nicht verfuegbar. Soll die 5h-Usage fuer diesen Task ignoriert werden?"
- Bei Nein: abbrechen
- Bei Ja: `usageGateDisabled=true`

## STEP 8 -- TASK BEIM SCHEDULER ANMELDEN

Lege vor dem Submit ein Bash-Flag fest:
    GATE_FLAG=""
    if [ "$usageGateDisabled" = "true" ]; then
      GATE_FLAG="-UsageGateDisabled"
    fi

Rufe den Scheduler synchron auf (Bash-Tool, ein Aufruf):
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$SCRIPT")" \
      -Mode submit-single \
      -CommandType TLA-develop \
      -PromptFile "$(cygpath -w "$PROMPT_FILE")" \
      -PlanFile "$(cygpath -w "$PLAN_FILE")" \
      -SolutionPath "<sln-pfad>" \
      -ResultFile "$(cygpath -w "$RESULT_FILE")" \
      -AllowNuget \
      $GATE_FLAG > "$(cygpath -w "$SUBMIT_FILE")"

Lies `SUBMIT_FILE` mit dem Read-Tool und parse das JSON.

Zeige dem Nutzer:
- Wave-Nummer
- `action` = `startable | queued`
- blockierende Task-IDs, falls vorhanden

## STEP 9 -- SCHEDULER-RUNNER STARTEN

Starte den Runner im Hintergrund (Bash-Tool mit `run_in_background: true`):
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$SCRIPT")" \
      -Mode run-single \
      -TaskId "<schedulerTaskId aus SUBMIT_FILE>" \
      -SolutionPath "<sln-pfad>"

Nutzer informieren:
- bei `startable`: "Scheduler-Task gestartet. Du wirst benachrichtigt."
- bei `queued`: "Scheduler-Task eingeplant und wartet auf seine Welle. Du wirst benachrichtigt, sobald ein finales Ergebnis vorliegt."

## STEP 10 -- ERGEBNIS VERARBEITEN (nach Task-Benachrichtigung)

Read `RESULT_FILE`. JSON parsen.

### `COMMITTED`
Zeige:
- `summary`
- `finalCategory`
- `files`
- `waveNumber`
- `commitMessage`

### `NO_CHANGE`
Zeige:
- `summary`
- `finalCategory`
- `noChangeReason`
- `artifacts`

### `FAILED`
Zeige:
- `summary`
- `finalCategory`
- `feedback`
- `artifacts`

### `ERROR`
Fehler zeigen.

### `SKIPPED_CONFLICT | SKIPPED_MERGE_CONFLICT | SKIPPED_BUILD_FAILURE`
Zeige:
- `summary`
- `mergeReason`
- `finalCategory`

Erklaere, dass der Scheduler den Task aus Sicherheitsgruenden nicht in den aktuellen HEAD uebernommen hat.
