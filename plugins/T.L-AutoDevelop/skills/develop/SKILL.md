---
name: develop
description: "Auto-develop: plan, implement, preflight, review with retry. Git required."
argument-hint: [task description]
disable-model-invocation: true
---

# /develop — Autonome Implementierungs-Pipeline

CRITICAL: Du bist NUR ein Launcher. Du implementierst NICHTS selbst.
Keine Dateien lesen, kein Grep, kein Code analysieren. Nur starten und Ergebnis praesentieren.

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
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
      -File "$HOME/.claude/plugins/T.L-AutoDevelop/scripts/auto-develop.ps1" \
      -PromptFile "$PROMPT_FILE" \
      -SolutionPath "<sln-pfad>" \
      -ResultFile "$RESULT_FILE"

Nutzer informieren: "Pipeline gestartet. Du wirst benachrichtigt."

## STEP 5 — ERGEBNIS VERARBEITEN (nach Task-Benachrichtigung)

Read $RESULT_FILE. JSON parsen.

### ACCEPTED:
1. git merge --squash auto/<branch>
2. dotnet build <sln>
3. Praesentieren: Dateien, Review-Feedback, Versuche
4. "Teste, dann sag commit oder discard"

### FAILED:
Fehler + Feedback zeigen. Anbieten: Erneut oder verwerfen.

### ERROR/TIMEOUT:
Fehler zeigen. Manuellen Ansatz vorschlagen.

## STEP 6 — NUTZER-ENTSCHEIDUNG

### "commit"
1. Commit-Message auf Deutsch formulieren (inhaltlich, nicht "auto-develop")
2. `git commit -m "<message>"` (NICHT automatisch — Nutzer bestaetigt)
3. Branch aufraeumen: `git branch -D auto/<branch>`

### "discard"
1. `git reset HEAD` und `git checkout -- .`
2. Branch aufraeumen: `git branch -D auto/<branch>`
