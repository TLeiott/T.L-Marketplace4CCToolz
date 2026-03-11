---
name: TLA-develop
description: "Fully autonomous develop pipeline. No confirmations, no stops. Git required."
argument-hint: [task description]
disable-model-invocation: true
---

# /TLA-develop — Vollautonome Implementierungs-Pipeline

CRITICAL: Du bist NUR ein Launcher. Du implementierst NICHTS selbst.
Keine Dateien lesen, kein Grep, kein Code analysieren. Nur starten und Ergebnis praesentieren.
KEIN User-Input nach dem Start. Alles laeuft automatisch bis zum Commit.

## STEP 1 — VALIDATE

Pruefe mit dem Bash-Tool (ein einziger Aufruf):
- `git rev-parse --is-inside-work-tree` → muss `true` sein
- `git status --porcelain` → muss leer sein

Falls nicht erfuellt: Nutzer informieren, abbrechen.

## STEP 2 — SOLUTION FINDEN

Glob nach `*.sln` und `*.slnx` im aktuellen Verzeichnis und bis zu 2 Elternverzeichnissen.
- Mehrere gefunden → Nutzer fragen welche
- Keine gefunden → Nutzer informieren, abbrechen

## STEP 3 — PROMPT SCHREIBEN

Ermittle zuerst den Windows-TEMP-Pfad (Bash-Tool):
    WIN_TEMP=$(powershell.exe -NoProfile -Command '$env:TEMP' | tr -d '\r')

Erstelle Verzeichnis und schreibe Prompt (Bash-Tool, ein Aufruf):
    TIMESTAMP=$(date +%s)
    DIR="$WIN_TEMP/claude-develop"
    mkdir -p "$DIR"
    PROMPT_FILE="$DIR/prompt-$TIMESTAMP.md"
    cat > "$PROMPT_FILE" << 'PROMPT_EOF'
    ## Task
    $ARGUMENTS

    ## Solution
    <absoluter Pfad zur .sln/.slnx>
    PROMPT_EOF

WICHTIG: $TEMP ist /tmp in bash — PowerShell kann das nicht lesen.
Verwende IMMER $WIN_TEMP fuer alle Pfade die an powershell.exe gehen.

## STEP 4 — PIPELINE STARTEN

RESULT_FILE="$WIN_TEMP/claude-develop/$TIMESTAMP-result.json"

Bash-Tool mit run_in_background: true:
    SCRIPT=$(find "$HOME/.claude/plugins/marketplaces" -path "*/T.L-AutoDevelop/scripts/auto-develop.ps1" -print -quit 2>/dev/null)
    if [ -z "$SCRIPT" ]; then
      SCRIPT=$(find "$HOME/.claude/plugins/cache" -path "*/T-L-AutoDevelop/*/scripts/auto-develop.ps1" -print -quit 2>/dev/null)
    fi
    if [ -z "$SCRIPT" ]; then echo "ERROR: auto-develop.ps1 nicht gefunden"; exit 1; fi
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$(cygpath -w "$SCRIPT")" \
      -PromptFile "$PROMPT_FILE" \
      -SolutionPath "<sln-pfad>" \
      -ResultFile "$RESULT_FILE" \
      -AllowNuget

Nutzer informieren: "Pipeline gestartet. Du wirst benachrichtigt."

## STEP 5 — ERGEBNIS VERARBEITEN (nach Task-Benachrichtigung)

Read $RESULT_FILE. JSON parsen.

### ACCEPTED:
Vollautomatisch, KEIN User-Input:
1. `git merge --squash auto/<branch>`
2. `dotnet build <sln>` — falls Build fehlschlaegt: `git reset HEAD .` und `git checkout -- .`, Branch aufraeumen, Fehler anzeigen, STOP.
3. Deutsche Commit-Message automatisch generieren (inhaltlich, basierend auf Task-Text und geaenderten Dateien)
4. `git commit -m "<generierte message>"`
5. Branch aufraeumen: `git branch -D auto/<branch>`
6. Ergebnis praesentieren: Dateien, Review-Feedback, Versuche, Commit-Message

### FAILED:
1. Fehler + Feedback anzeigen
2. Branch wurde bereits von auto-develop.ps1 aufgeraeumt

### ERROR/TIMEOUT:
1. Fehler anzeigen
2. Branch aufraeumen falls noetig: `git branch -D auto/<branch>` (ignoriere Fehler)
