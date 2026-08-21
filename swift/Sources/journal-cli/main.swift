// journal-cli — read and write Apple Journal entries straight from its Core Data store.
//
// Store: ~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite
// ("moments" is Journal's internal codename.) Requires Full Disk Access.
import Foundation

let HELP = """
USAGE: journal-cli [--db PATH] <command> [options]

Read and write Apple Journal entries from the local Core Data store.

READ
  list      [--limit N] [--since D] [--until D] [--include-empty] [--full] [--json]
  show      <id> [--json]
  search    <query> [--limit N] [--full] [--json]
  export    --dir DIR [--format md|json]
  stats
  journals  [--json]
  deleted   [--json]
  doctor

WRITE (guarded: --live required against the real store; auto-backup first)
  write     [--title T] [--body B] [--body-file F] [--body-rtf F] [--date D] [--bookmark]
            [--markdown]
            [--media PATH...] [--live-photo IMAGE VIDEO] [--no-resize]
            [--photos-link] [--link URL] [--link-title T]
            [--lat N --lon N] [--place P] [--city C] [--journal NAME] [--live]
  edit      <id> [--title T] [--body B] [--body-file F] [--body-rtf F] [--date D]
            [--bookmark | --no-bookmark] [--add-media PATH...] [--no-resize]
            [--photos-link] [--add-link URL] [--link-title T]
            [--lat N --lon N] [--place P] [--city C] [--clear-location]
            [--remove-media ID...] [--remove-all-media]
            [--journal NAME] [--force] [--live]
  delete    <id> [--hard] [--force] [--live]
  restore   <id> [--live]
  empty     [--force] [--live]
  sync-journals [--journal NAME] [--live]
            re-upload custom-journal memberships after a direct-store import
  sandbox   --dir DIR [--from DB]      copy the store somewhere safe for testing
  render    [--body B | --body-file F | stdin] [--plain]
            render Markdown to RTF (or plain text) on stdout; writes nothing

  --markdown renders the body (and de-escapes the title) as Markdown into
  Journal's rich text: headings and **bold** become real formatting rather
  than literal syntax. --body-rtf F stores a prepared RTF file verbatim.

  Every mutating command also takes --dry-run (print the plan, write nothing)
  and --accept-risk (one-time risk acknowledgment; see the README warning).
"""

var argv = Array(CommandLine.arguments.dropFirst())

// global --db (also honored via $JOURNAL_DB)
if let i = argv.firstIndex(of: "--db") {
    guard i + 1 < argv.count else { die("--db needs a value") }
    DB_PATH = (argv[i + 1] as NSString).expandingTildeInPath
    argv.removeSubrange(i...(i + 1))
}

guard let cmd = argv.first, cmd != "--help", cmd != "-h", cmd != "help" else {
    print(HELP)
    exit(argv.first == nil ? 1 : 0)
}
let rest = Array(argv.dropFirst())

let boolFlags: Set<String> = ["--json", "--full", "--include-empty", "--bookmark",
                              "--dry-run", "--accept-risk", "--markdown", "--plain",
                              "--no-bookmark", "--live", "--hard", "--force",
                              "--clear-location", "--remove-all-media",
                              "--photos-link", "--no-resize"]
let valueFlags: Set<String> = ["--limit", "--since", "--until", "--dir", "--format",
                               "--title", "--body", "--body-file", "--body-rtf", "--date",
                               "--lat", "--lon", "--place", "--city", "--journal",
                               "--link", "--link-title", "--add-link", "--from"]
let listFlags: Set<String> = ["--media", "--add-media", "--live-photo", "--remove-media"]

let a = Args(rest, listFlags: listFlags, valueFlags: valueFlags, boolFlags: boolFlags)

switch cmd {
case "list":     cmdList(a)
case "show":     cmdShow(a)
case "search":   cmdSearch(a)
case "export":   cmdExport(a)
case "stats":    cmdStats(a)
case "journals": cmdJournals(a)
case "deleted":  cmdDeleted(a)
case "doctor":   cmdDoctor(a)
case "write":    cmdWrite(a)
case "edit":     cmdEdit(a)
case "delete":   cmdDelete(a)
case "restore":  cmdRestore(a)
case "empty":    cmdEmpty(a)
case "sync-journals": cmdSyncJournals(a)
case "sandbox":  cmdSandbox(a)
case "render":   cmdRender(a)
default:
    die("unknown command '\(cmd)'\n\n\(HELP)")
}
