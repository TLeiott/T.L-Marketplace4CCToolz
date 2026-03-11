---
name: TLA-develop-batch
description: "Fully autonomous batch develop pipeline. No confirmations, no stops."
argument-hint: [path to tasks.md]
disable-model-invocation: true
---

# /TLA-develop-batch — Vollautonome Parallele Implementierungs-Pipeline

CRITICAL: Du bist NUR ein Launcher. Keine Dateien lesen, kein Code analysieren.
KEIN User-Input nach dem Start. Alles laeuft automatisch bis zum Commit.

## STEP 1 — VALIDATE
Pruefe mit dem Bash-Tool (ein einziger Aufruf):
- `git rev-parse --is-inside-work-tree` → muss `true` sein
- `git status --porcelain` → muss leer sein

Falls nicht erfuellt: Nutzer informieren, abbrechen.

## STEP 2 — TASK-DATEI LESEN
Lies die Datei unter $ARGUMENTS mit dem Read-Tool. Parse Bullets (- oder *).
Jeder Bullet = ein Task. Merke dir die Task-Texte.

## STEP 3 — SOLUTION FINDEN
Glob nach *.sln und *.slnx im aktuellen Verzeichnis und bis zu 2 Elternverzeichnissen.
- Mehrere gefunden → Nutzer fragen welche
- Keine gefunden → abbrechen

## STEP 4 — WINDOWS TEMP + PROMPTS SCHREIBEN

Ermittle zuerst den Windows-TEMP-Pfad und Timestamp (Bash-Tool, ein Aufruf):
    WIN_TEMP=$(powershell.exe -NoProfile -Command '$env:TEMP' | tr -d '\r')
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)

WICHTIG: $TEMP ist /tmp in bash — PowerShell kann das nicht lesen.
Verwende IMMER $WIN_TEMP fuer alle Pfade die an powershell.exe gehen.

Fuer jeden Task (id = 1, 2, 3, ...) eine Prompt-Datei schreiben:
    Pfad: $WIN_TEMP/claude-develop/batch-$TIMESTAMP-<id>-prompt.md
    Inhalt:
        ## Task
        <task text>

        ## Solution
        <sln path>

Result-Pfade merken: $WIN_TEMP/claude-develop/batch-$TIMESTAMP-<id>-result.json

## STEP 5 — ALLE PIPELINES PARALLEL STARTEN

Fuer JEDEN Task einen eigenen Bash-Aufruf mit run_in_background: true.
ALLE Bash-Aufrufe in EINER EINZIGEN Nachricht (parallel!):

    SCRIPT=$(find "$HOME/.claude" -path "*/T*AutoDevelop/scripts/auto-develop.ps1" -print -quit 2>/dev/null)
    if [ -z "$SCRIPT" ]; then echo "ERROR: auto-develop.ps1 nicht gefunden"; exit 1; fi
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$SCRIPT")" \
      -PromptFile "<prompt-pfad>" \
      -SolutionPath "<sln-pfad>" \
      -ResultFile "<result-pfad>" \
      -TaskName "batch-<timestamp>-<id>" \
      -SkipRun

Nutzer informieren: "N Pipelines gestartet. Du wirst nach Abschluss benachrichtigt."

## STEP 6 — ERGEBNISSE SAMMELN (nach ALLEN Benachrichtigungen)

Warte bis ALLE Background-Tasks fertig sind. Dann:
Lies JEDE Result-Datei mit dem Read-Tool (parallel). JSON parsen.

Uebersichtstabelle anzeigen:

    | # | Task              | Status   | Dateien | Versuche |
    |---|-------------------|----------|---------|----------|
    | 1 | Add logging       | ACCEPTED | 3       | 1        |
    | 2 | Fix validation    | FAILED   | 0       | 3        |

Falls KEINE Tasks ACCEPTED: Fehler zeigen, abbrechen.

## STEP 7 — SEQUENZIELL MERGEN + AUTO-COMMITTEN

Pro ACCEPTED Task (in Reihenfolge), vollautomatisch OHNE User-Bestaetigungen:

1. `git merge --squash auto/batch-<timestamp>-<id>`
2. Falls Merge-Konflikt → `git merge --abort`, als SKIPPED markieren, weiter
3. Falls sauber → `dotnet build <sln>`
4. Falls Build fehlschlaegt → `git reset HEAD .` und `git checkout -- .`, als SKIPPED markieren, weiter
5. Falls Build OK → Deutsche Commit-Message automatisch generieren (inhaltlich, basierend auf Task-Text und geaenderten Dateien)
6. `git commit -m "<generierte message>"`
7. Branch aufraeumen: `git branch -D auto/batch-<timestamp>-<id>`

## STEP 8 — ZUSAMMENFASSUNG

Endergebnis anzeigen:

    3/4 Tasks committed. 1 uebersprungen (Merge-Konflikt auf B.cs).

Fuer SKIPPED Tasks:
- Grund nennen (Konflikt / Build-Fehler)
- Branch aufraeumen: `git branch -D auto/batch-<timestamp>-<id>`

Fuer FAILED/ERROR Tasks:
- Fehler + Feedback zeigen
- Branch wurde bereits von auto-develop.ps1 aufgeraeumt
