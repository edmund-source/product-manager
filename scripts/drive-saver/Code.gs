/**
 * Helios supplier attachment saver (Google Apps Script, runs in Edmund's account).
 *
 * Every hour it copies new email attachments from known suppliers into each
 * supplier's Drive folder. Which senders belong to which supplier, and the
 * folder, come from the "Folders" tab of the "Supplier folders" sheet in
 * "Helios Suppliers", which the weekly supplier inbox scanner keeps up to
 * date. Each saved file is logged in the "Saved" tab, so it is saved once and
 * the scanner knows which files to read.
 *
 * It only reads mail and creates files in those folders. It never sends,
 * labels, archives, moves or deletes anything.
 *
 * Setup: paste into a new project at script.google.com, run `install` once and
 * allow the permissions it asks for. To stop it, delete its trigger (clock icon).
 */
const SHEET_ID = '1TNHcqPLbzHp4CKP_ChkHQUdmQKf0ICRKEnxAF5tUUPc';
const LOOKBACK = '3d';                // hourly runs overlap; the Saved log de-duplicates
const MAX_RUN_MS = 5 * 60 * 1000;     // Apps Script stops a run at 6 minutes
const SKIP_EXT = /\.(ics|vcf|p7s|asc|sig)$/i;
const SMALL_IMAGE_BYTES = 150 * 1024; // logos and signature images

function install() {
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'saveSupplierAttachments')
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('saveSupplierAttachments').timeBased().everyHours(1).create();
  saveSupplierAttachments();
}

/** One-off: save the last 30 days for every supplier already in the sheet. */
function backfill30Days() { saveSupplierAttachments('30d'); }

function saveSupplierAttachments(lookback) {
  const started = Date.now();
  const book = SpreadsheetApp.openById(SHEET_ID);
  const folders = book.getSheetByName('Folders');
  const saved = book.getSheetByName('Saved');
  const done = new Set(saved.getLastRow() > 1
    ? saved.getRange(2, 3, saved.getLastRow() - 1, 6).getValues().map((r) => r[0] + '|' + r[5])
    : []);

  // Folders columns: company, senders, folder_id, ...
  const rows = folders.getLastRow() > 1 ? folders.getRange(2, 1, folders.getLastRow() - 1, 3).getValues() : [];
  for (const [company, senders, folderId] of rows) {
    if (Date.now() - started > MAX_RUN_MS) break;
    const from = String(senders || '').split(/[,;\s]+/).map((s) => s.trim().replace(/^@/, '').toLowerCase()).filter(Boolean);
    if (!company || !folderId || !from.length) continue;
    let folder;
    try { folder = DriveApp.getFolderById(String(folderId)); } catch (e) { continue; }

    const query = 'from:(' + from.join(' OR ') + ') has:attachment newer_than:' + (typeof lookback === 'string' ? lookback : LOOKBACK);
    for (const thread of GmailApp.search(query, 0, 50)) {
      for (const msg of thread.getMessages()) {
        if (Date.now() - started > MAX_RUN_MS) break;
        const sender = msg.getFrom().toLowerCase();
        if (!from.some((f) => sender.includes(f))) continue; // skip Helios replies in the same thread
        for (const att of msg.getAttachments({ includeInlineImages: false })) {
          const name = att.getName() || 'attachment';
          const type = att.getContentType() || '';
          const size = att.getSize();
          if (SKIP_EXT.test(name) || (type.indexOf('image/') === 0 && size < SMALL_IMAGE_BYTES)) continue;
          const key = msg.getId() + '|' + name;
          if (done.has(key)) continue;
          const day = Utilities.formatDate(msg.getDate(), 'Asia/Manila', 'yyyy-MM-dd');
          const file = folder.createFile(att.copyBlob()).setName(day + ' ' + name);
          saved.appendRow([new Date(), company, msg.getId(), thread.getId(), msg.getDate(), msg.getFrom(),
            msg.getSubject(), name, file.getId(), file.getUrl(), size, type, '']);
          done.add(key);
        }
      }
    }
  }
}
