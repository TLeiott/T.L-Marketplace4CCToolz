---
name: develop-batch
description: "Auto-develop multiple tasks in scheduler-guided, statusline-aware batches via git worktrees."
argument-hint: [path to tasks.md]
disable-model-invocation: true
---

# /develop-batch — Geplante Batch-Implementierungs-Pipeline

CRITICAL: Du bist Launcher UND Scheduler. Du implementierst NICHTS selbst.
Vor dem Start darfst du read-only Kontext sammeln, um sichere Parallelitaet zu bestimmen.
Erlaubt vor dem Pipeline-Start: Read, Glob, Grep, Bash.
Verboten vor dem Pipeline-Start: Edit, Write in Repo-Dateien, Commits, Builds ausser den unten beschriebenen Validierungs-/Merge-Schritten.

## STEP 1 — VALIDATE
Pruefe mit dem Bash-Tool (ein einziger Aufruf):
- `git rev-parse --is-inside-work-tree` → muss `true` sein
- `git status --porcelain` → muss leer sein

Falls nicht erfuellt: Nutzer informieren, abbrechen.

## STEP 2 — TASK-DATEI LESEN
Lies die Datei unter $ARGUMENTS mit dem Read-Tool. Parse Bullets (- oder *).
Jeder Bullet = ein Task. Merke dir:
- `id` in Originalreihenfolge ab 1
- `taskText`
- `originalOrder`

## STEP 3 — SOLUTION FINDEN
Glob nach *.sln und *.slnx im aktuellen Verzeichnis und bis zu 2 Elternverzeichnissen.
- Mehrere gefunden → Nutzer fragen welche
- Keine gefunden → abbrechen

## STEP 4 — WINDOWS TEMP + BATCH-RUN BASIS

Ermittle zuerst den Windows-TEMP-Pfad und Timestamp (Bash-Tool, ein Aufruf):
    WIN_TEMP=$(powershell.exe -NoProfile -Command '$env:TEMP' | tr -d '\r')
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BATCH_DIR="$WIN_TEMP/claude-develop"
    mkdir -p "$BATCH_DIR"

WICHTIG: $TEMP ist /tmp in bash — PowerShell kann das nicht lesen.
Verwende IMMER $WIN_TEMP fuer alle Pfade die an powershell.exe gehen.

Merke ausserdem:
- Plan-Datei: `$BATCH_DIR/batch-$TIMESTAMP-plan.json`
- Usage-Gate-Log: `$BATCH_DIR/batch-$TIMESTAMP-usage-gate.jsonl`
- Fuer jeden Task Prompt-Datei: `$BATCH_DIR/batch-$TIMESTAMP-<id>-prompt.md`
- Fuer jeden Task Result-Datei: `$BATCH_DIR/batch-$TIMESTAMP-<id>-result.json`

## STEP 5 — REPO-KONTEXT INVENTAR (READ-ONLY)
Baue VOR jeder Task-Planung einen kompakten Repo-Ueberblick nur read-only:
- Solution-Verzeichnis
- relevante Projekte (`*.csproj`)
- Top-Level Module/Ordner unterhalb der Solution, ohne `bin`, `obj`, `.git`, `.vs`, `node_modules`, `packages`
- gemeinsame Konfigurationsdateien wie `Directory.Build.*`, `Directory.Packages.props`, `global.json`, `nuget.config`, `appsettings*.json`, `*.props`, `*.targets`
- `CLAUDE.md`, falls vorhanden

Lade nur so viel Kontext, wie fuer die Batch-Planung noetig ist. Keine Volltext-Ladung der ganzen Codebase.

## STEP 6 — KONTEXTPASS PRO TASK (READ-ONLY, PARALLEL)
Analysiere fuer JEDEN Task read-only, welche Dateien/Bereiche voraussichtlich betroffen sind. Nutze Read/Glob/Grep und den Repo-Ueberblick. Diese Analyse dient NUR der Batch-Planung.

Fuer jeden Task MUSST du einen Datensatz bilden mit:
- `taskId`
- `taskText`
- `taskClassGuess`
- `likelyAreas` (Projekte/Module/Ordner)
- `likelyFiles` (konkrete relative Pfade, nur wenn belastbar)
- `searchPatterns` (konkrete Suchmuster oder Globs, wenn keine exakten Dateien klar sind)
- `dependencyHints` (Task-IDs oder leer)
- `conflictRisk` = `LOW | MEDIUM | HIGH`
- `confidence` = `HIGH | MEDIUM | LOW`
- `rationale` = 1-3 kurze evidenzbasierte Saetze

Heuristik:
- Bevorzuge konkrete Dateien ueber breite Module.
- Wenn du nur ein gemeinsames Modul, Projekt oder Konfigurationsdateien eingrenzen kannst, markiere das konservativ als `MEDIUM` oder `HIGH`.
- Wenn die Aufgabe auf gemeinsame Vertrage, APIs, DTOs, Schemas, Projektdateien oder globale Config zielt, behandle sie als breit.
- Wenn die Aufgabe semantisch wie ein Folge- oder Voraussetzungsschritt einer anderen wirkt, setze `dependencyHints`.
- Wenn du Disjunktheit nicht belastbar nachweisen kannst, plane NICHT parallel.

## STEP 7 — KONFLIKT- UND ABHAENGIGKEITSGRAPH
Baue aus den Task-Datensaetzen einen konservativen Graphen.

Lege eine Konfliktkante zwischen zwei Tasks an, wenn mindestens eines gilt:
- gleiche `likelyFiles`
- gleiche `.csproj`, `.sln`, `.slnx`, `.props`, `.targets`, `json`, `yaml`, `config`-Datei
- gleiches Top-Level Modul/Projekt bei `confidence != HIGH`
- ein `searchPattern` oder breiter Bereich des einen Tasks deckt den Bereich des anderen mit ab
- einer der beiden Tasks ist breit/unsicher genug, dass Konfliktfreiheit nicht klar belegbar ist

Lege eine Abhaengigkeitskante an, wenn mindestens eines gilt:
- ein Task scheint einen Vertrag/API/Schema/Refactor zu aendern, den ein anderer vermutlich nutzt
- ein Tasktext klingt wie Vorarbeit oder Folgearbeit eines anderen
- die read-only Analyse deutet auf dieselbe Feature-Kette mit notwendiger Reihenfolge

Regel: Wenn du unsicher bist, behandle es als Konflikt oder Abhaengigkeit und serialisiere.

## STEP 8 — WAVES BILDEN + PLAN ARTEFAKT
Bilde aus dem Graphen konservative Ausfuehrungswellen:
- Tasks duerfen nur dann in derselben Welle liegen, wenn weder Konflikt- noch Abhaengigkeitskante besteht.
- Originalreihenfolge innerhalb einer Welle beibehalten.
- Standard-Maximalparallelitaet: `20`
- Effektive Parallelitaet pro Welle = `min(20, Anzahl startbereiter Tasks dieser Welle)`
- Wenn eine Welle mehr als 20 Tasks enthaelt, starte innerhalb der Welle immer nur so viele, bis wieder ein Slot frei wird.

Schreibe die Batch-Planung als JSON nach `$BATCH_DIR/batch-$TIMESTAMP-plan.json` mit mindestens:
- `timestamp`
- `solutionPath`
- `maxConcurrency`
- `tasks` (alle Task-Datensaetze)
- `edges` mit `from`, `to`, `type` (`conflict|dependency`), `reason`
- `waves` mit Task-IDs in Startreihenfolge

Zeige dem Nutzer vor dem Start eine kompakte Uebersicht:

    | # | Wave | Risiko | Bereiche/Dateien | Parallel? | Grund |
    |---|------|--------|------------------|-----------|-------|
    | 1 | 1    | LOW    | Foo/, Bar.cs     | Ja        | Disjunkt |
    | 2 | 2    | HIGH   | Directory.Build.props | Nein | Shared config |

Hinweistext:
- "Batch-Plan erstellt. Parallelitaet wird konservativ nach Dateibereichen und Abhaengigkeiten gesteuert."
- "Maximal 20 Pipelines gleichzeitig, tatsaechlich nur konfliktfreie Tasks."

## STEP 9 — 5H-USAGE-GATE PREFLIGHT
Finde das Helferskript fuer den lokalen Claude-Usage-Gate:

    GATE_SCRIPT=$(find "$HOME/.claude/plugins/marketplaces" -path "*/T.L-AutoDevelop/scripts/claude-usage-gate.ps1" -print -quit 2>/dev/null)
    if [ -z "$GATE_SCRIPT" ]; then
      GATE_SCRIPT=$(find "$HOME/.claude/plugins/cache" -path "*/T-L-AutoDevelop/*/scripts/claude-usage-gate.ps1" -print -quit 2>/dev/null)
    fi
    if [ -z "$GATE_SCRIPT" ]; then echo "ERROR: claude-usage-gate.ps1 nicht gefunden"; exit 1; fi

Fuehre SOFORT, solange der Nutzer noch praesent ist, einen Preflight-Probe aus:

    START_GATE_JSON="$BATCH_DIR/batch-$TIMESTAMP-usage-start.json"
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$GATE_SCRIPT")" \
      -Mode probe \
      -ThresholdPercent 90 > "$(cygpath -w "$START_GATE_JSON")"

Lies `START_GATE_JSON` mit dem Read-Tool und parse das JSON.

Wenn `processStatus == "fatal"`:
- fatalen Fehler mit `errors` zeigen
- Batch abbrechen

Wenn `ok=true`:
- `source`, `fiveHourUtilization`, `sevenDayUtilization`, `fiveHourResetAt` kurz anzeigen
- klar dazusagen: NUR `fiveHourUtilization` blockiert neue Starts; `sevenDayUtilization` ist reine Info
- den JSON-Inhalt als erste Zeile in `$BATCH_DIR/batch-$TIMESTAMP-usage-gate.jsonl` uebernehmen
- `usageGateDisabled=false` merken

Wenn `processStatus != "fatal"` UND `ok=false`:
- `errors` kurz zeigen
- Nutzer SOFORT fragen: "Statusline und Usage-Cache sind nicht verfuegbar. Soll die 5h-Usage fuer diesen Batch ignoriert werden?"
- Bei Nein: abbrechen
- Bei Ja: `usageGateDisabled=true` fuer den gesamten Batch merken und diese Entscheidung in `$BATCH_DIR/batch-$TIMESTAMP-usage-gate.jsonl` vermerken

## STEP 10 — PROMPTS SCHREIBEN
Fuer jeden Task eine Prompt-Datei schreiben:
    Pfad: $BATCH_DIR/batch-$TIMESTAMP-<id>-prompt.md
    Inhalt:
        ## Task
        <task text>

        ## Solution
        <sln path>

## STEP 11 — PIPELINES WELLENWEISE STARTEN

Starte die Tasks WELLENWEISE gemaess Batch-Plan.
Nutze pro Task einen eigenen Bash-Aufruf mit `run_in_background: true`.
Innerhalb einer Welle:
- Starte nur konfliktfreie Tasks.
- Halte hoechstens 20 gleichzeitige Pipelines offen.
- Wenn eine Pipeline fertig ist, darf innerhalb derselben Welle die naechste wartende Pipeline starten.
- Erst wenn eine Welle komplett fertig ist, beginne die naechste Welle.

WICHTIG: Vor JEDEM individuellen Pipeline-Start muss der 5h-Usage-Gate erneut geprueft werden.

Falls `usageGateDisabled != true`:
1. Fuehre VOR dem Start des konkreten Tasks aus:

       GATE_JSON="$BATCH_DIR/batch-$TIMESTAMP-usage-wave-<wave>-task-<id>.json"
       powershell.exe -NoProfile -ExecutionPolicy Bypass \
         -File "$(cygpath -w "$GATE_SCRIPT")" \
         -Mode wait \
         -ThresholdPercent 90 > "$(cygpath -w "$GATE_JSON")"

2. Lies `GATE_JSON` mit dem Read-Tool und parse das JSON.
3. Falls `ok=true`:
   - Wenn `waitedSeconds > 0`: Nutzer kurz informieren, dass der Start fuer diesen Task wegen 5h-Usage pausiert war
   - `source`, `fiveHourUtilization`, `waitedSeconds` in `$BATCH_DIR/batch-$TIMESTAMP-usage-gate.jsonl` vermerken
   - NUR danach die Pipeline starten
4. Falls `processStatus == "fatal"` oder das JSON nicht lesbar ist:
   - NICHT unendlich blockieren
   - Warnung zeigen: Usage-Gate Helper ist waehrend des Laufs fatal ausgefallen
   - `usageGateDisabled=true` fuer den Rest des Batch setzen
   - in `$BATCH_DIR/batch-$TIMESTAMP-usage-gate.jsonl` vermerken
   - den Task trotzdem starten
5. Falls `processStatus != "fatal"` UND `ok=false`:
   - Warnung zeigen: Statusline/Cache waehrend des Laufs nicht mehr nutzbar
   - `errors` kurz zeigen
   - `usageGateDisabled=true` fuer den Rest des Batch setzen
   - in `$BATCH_DIR/batch-$TIMESTAMP-usage-gate.jsonl` vermerken
   - den Task trotzdem starten

Falls `usageGateDisabled == true`:
- keine weiteren Gate-Checks mehr
- Pipelines normal gemaess Wellenplan starten

    SCRIPT=$(find "$HOME/.claude/plugins/marketplaces" -path "*/T.L-AutoDevelop/scripts/auto-develop.ps1" -print -quit 2>/dev/null)
    if [ -z "$SCRIPT" ]; then
      SCRIPT=$(find "$HOME/.claude/plugins/cache" -path "*/T-L-AutoDevelop/*/scripts/auto-develop.ps1" -print -quit 2>/dev/null)
    fi
    if [ -z "$SCRIPT" ]; then echo "ERROR: auto-develop.ps1 nicht gefunden"; exit 1; fi
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$SCRIPT")" \
      -PromptFile "<prompt-pfad>" \
      -SolutionPath "<sln-pfad>" \
      -ResultFile "<result-pfad>" \
      -TaskName "batch-<timestamp>-<id>" \
      -SkipRun

Nutzer pro Welle informieren:
- "Welle X/Y gestartet: N Task(s), maximal 20 gleichzeitig."
- Nach Wellenende kurz melden, welche Tasks abgeschlossen sind.

## STEP 12 — ERGEBNISSE SAMMELN (nach ALLEN Benachrichtigungen)

Warte bis ALLE Background-Tasks fertig sind. Dann:
Lies JEDE Result-Datei mit dem Read-Tool (parallel). JSON parsen.

Uebersichtstabelle anzeigen:

    | # | Wave | Task              | Status   | Dateien | Versuche |
    |---|------|-------------------|----------|---------|----------|
    | 1 | 1    | Add logging       | ACCEPTED | 3       | 1        |
    | 2 | 2    | Fix validation    | FAILED   | 0       | 3        |

Falls KEINE Tasks `ACCEPTED`: Fehler zeigen, `finalCategory`/`summary` nennen, abbrechen.

## STEP 13 — ACTUAL-OVERLAP RECHECK VOR DEM MERGE
Bevor du irgendetwas merge-st:
- Betrachte fuer jeden `ACCEPTED` Task die tatsaechlichen `result.files`.
- Verarbeite `ACCEPTED` Tasks in geplanter Wellenreihenfolge und innerhalb der Welle in Originalreihenfolge.
- Fuehre eine Menge `mergedFiles` aller bereits erfolgreich uebernommenen Dateien.

Wenn fuer einen noch nicht gemergten `ACCEPTED` Task gilt:
- `result.files` ueberschneidet sich mit `mergedFiles`, oder
- `result.files` ist leer UND der Task stammt aus einer Welle mit Parallelitaet > 1 UND seine Planung war unsicher,

dann:
- NICHT merge-n
- als `SKIPPED_CONFLICT` markieren
- Begruendung speichern: "Unerwartete Ueberschneidung nach Lauf gegen bereits uebernommene Aenderungen."
- Branch spaeter aufraeumen

Leere `result.files` ohne zusaetzliches Risiko darfst du weiter zum normalen Merge-Fallback durchlassen.

## STEP 14 — SEQUENZIELL MERGEN + COMMITTEN

Pro verbleibendem `ACCEPTED` Task (in geplanter Reihenfolge):

1. `git merge --squash auto/batch-<timestamp>-<id>`
2. Falls Merge-Konflikt → `git merge --abort`, als SKIPPED markieren, weiter
3. Falls sauber → `dotnet build <sln>`
4. Falls Build fehlschlaegt → `git reset HEAD .` und `git checkout -- .`, als SKIPPED markieren, weiter
5. Falls Build OK → Commit mit deutscher Message (inhaltlich, nicht "auto-develop")
   NICHT automatisch committen — Nutzer bestaetigt jede Commit-Message.
6. Branch aufraeumen: `git branch -D auto/batch-<timestamp>-<id>`
7. Nach erfolgreichem Commit `result.files` zu `mergedFiles` hinzufuegen

## STEP 15 — ZUSAMMENFASSUNG

Endergebnis anzeigen:

    7/9 Tasks committed. 2 uebersprungen (1 Merge-Konflikt, 1 unerwartete Datei-Ueberschneidung).

Wenn relevant, zusaetzlich nennen:
- wie oft der 5h-Usage-Gate Starts verzoegert hat
- ob Statusline oder Cache als Quelle verwendet wurde
- ob der Gate spaeter deaktiviert werden musste

Fuer SKIPPED Tasks:
- Grund nennen (`Datei-Ueberschneidung`, `Merge-Konflikt`, `Build-Fehler`)
- Anbieten: `/develop "<original task text>"` gegen aktuellen HEAD
- Branch aufraeumen: `git branch -D auto/batch-<timestamp>-<id>`

Fuer FAILED/ERROR/NO_CHANGE Tasks:
- `finalCategory`, `summary`, `artifacts.runDir` zeigen
- Branch wurde bereits von auto-develop.ps1 aufgeraeumt
