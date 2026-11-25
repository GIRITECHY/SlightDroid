// SlightDroid launcher: file transfer between Windows and Android (Android's shared storage, /sdcard).
// Browse Android storage, send files from the PC (button or drag & drop into the list), save files
// to the PC, delete. Uses the ADB file-sync protocol (AdbSync), so no adb.exe is needed.
// C# 5 / .NET Framework 4.x.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace SlightDroid {
    sealed class FilesForm : Form {
        const string Root = "/sdcard";
        readonly Vm vm; readonly VmState st;
        string dir = Root;
        readonly ListView list;
        readonly TextBox pathBox;
        readonly ToolStripButton upBtn;
        bool dragging;

        public FilesForm(Vm vm, VmState st) {
            this.vm = vm; this.st = st;
            Text = "SlightDroid - Files (Windows <-> Android)";
            Icon = AppIcon.Get(32);
            StartPosition = FormStartPosition.CenterScreen;
            Font = SystemFonts.MessageBoxFont;
            Size = Scale(new Size(760, 520));
            MinimumSize = Scale(new Size(520, 320));

            var tools = new ToolStrip { GripStyle = ToolStripGripStyle.Hidden, Padding = new Padding(6, 4, 6, 4) };
            upBtn = new ToolStripButton("Up", null, (s, e) => Go(ParentDir(dir)));
            tools.Items.Add(upBtn);
            tools.Items.Add(new ToolStripButton("Refresh", null, (s, e) => Go(dir)));
            tools.Items.Add(new ToolStripSeparator());
            tools.Items.Add(new ToolStripButton("Send from PC...", null, (s, e) => PickAndSend()));
            tools.Items.Add(new ToolStripButton("Save to PC...", null, (s, e) => SaveSelected()));
            tools.Items.Add(new ToolStripSeparator());
            tools.Items.Add(new ToolStripButton("New folder", null, (s, e) => NewFolder()));
            tools.Items.Add(new ToolStripButton("Delete", null, (s, e) => DeleteSelected()));

            pathBox = new TextBox { Dock = DockStyle.Top, ReadOnly = true, BorderStyle = BorderStyle.FixedSingle };
            var hint = new Label { Dock = DockStyle.Bottom, Height = Scale(new Size(0, 26)).Height, TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(8, 0, 0, 0), ForeColor = SystemColors.GrayText,
                Text = "Drag files in from Windows to send them, or drag them out to Explorer. Ctrl+C / Ctrl+V copy between Windows and Android; right-click for more." };

            list = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, AllowDrop = true, HideSelection = false };
            list.Columns.Add("Name", Scale(new Size(380, 0)).Width);
            list.Columns.Add("Size", Scale(new Size(100, 0)).Width, HorizontalAlignment.Right);
            list.Columns.Add("Modified", Scale(new Size(160, 0)).Width);
            list.SmallImageList = new ImageList { ColorDepth = ColorDepth.Depth32Bit, ImageSize = new Size(16, 16) };
            list.SmallImageList.Images.Add("dir", ShellIcon(true));
            list.SmallImageList.Images.Add("file", ShellIcon(false));
            list.DoubleClick += (s, e) => { var it = Selected().FirstOrDefault(); if (it.IsDir) Go(Join(dir, it.Name)); };
            list.KeyDown += (s, e) => {
                if (e.KeyCode == Keys.Delete) DeleteSelected();
                else if (e.KeyCode == Keys.Back || (e.Alt && e.KeyCode == Keys.Up)) Go(ParentDir(dir));
                else if (e.KeyCode == Keys.F5) Go(dir);
                else if (e.KeyCode == Keys.F2) RenameSelected();
                else if (e.KeyCode == Keys.Enter) OpenSelected();
                else if (e.Control && e.Shift && e.KeyCode == Keys.N) NewFolder();
                else if (e.Control && e.KeyCode == Keys.A) { foreach (ListViewItem i in list.Items) i.Selected = true; }
                else if (e.Control && e.KeyCode == Keys.C) CopyToClipboard();
                else if (e.Control && e.KeyCode == Keys.V) PasteFromClipboard();
                else if (e.Control && e.KeyCode == Keys.S) SaveSelected();
                else return;
                e.Handled = true; e.SuppressKeyPress = true;
            };
            var menu = new ContextMenuStrip();
            menu.Items.Add("Open", null, (s, e) => OpenSelected());
            menu.Items.Add("Save to PC...    Ctrl+S", null, (s, e) => SaveSelected());
            menu.Items.Add("Copy    Ctrl+C", null, (s, e) => CopyToClipboard());
            menu.Items.Add("Paste from Windows    Ctrl+V", null, (s, e) => PasteFromClipboard());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Rename    F2", null, (s, e) => RenameSelected());
            menu.Items.Add("Delete    Del", null, (s, e) => DeleteSelected());
            menu.Items.Add("New folder    Ctrl+Shift+N", null, (s, e) => NewFolder());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Refresh    F5", null, (s, e) => Go(dir));
            list.ContextMenuStrip = menu;
            // drag files OUT of the list onto Explorer / the desktop: they are copied to a temporary folder first
            list.ItemDrag += (s, e) => {
                var tmp = DownloadSelectedToTemp();
                if (tmp == null) return;
                var data = new DataObject(DataFormats.FileDrop, tmp);
                dragging = true;
                try { list.DoDragDrop(data, DragDropEffects.Copy); } finally { dragging = false; }
            };            list.DragEnter += (s, e) => e.Effect = !dragging && e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
            list.DragDrop += (s, e) => {
                var f = e.Data.GetData(DataFormats.FileDrop) as string[];
                if (f != null) BeginInvoke((Action)(() => { SendToAndroid(vm, st, f, dir); Go(dir); }));
            };

            Controls.Add(list); Controls.Add(pathBox); Controls.Add(tools); Controls.Add(hint);
            Shown += (s, e) => Go(Root);
        }

        Size Scale(Size s) {
            float f; using (var g = CreateGraphics()) f = g.DpiX / 96f;
            return new Size((int)(s.Width * f), (int)(s.Height * f));
        }

        static string Join(string a, string b) { return a.TrimEnd('/') + "/" + b; }
        static string ParentDir(string p) { if (p == Root) return Root; int i = p.LastIndexOf('/'); return i <= 0 ? Root : p.Substring(0, i); }

        IEnumerable<AdbSync.Entry> Selected() {
            return list.SelectedItems.Cast<ListViewItem>().Select(i => (AdbSync.Entry)i.Tag);
        }

        static string Human(long b) {
            if (b < 1024) return b + " B";
            if (b < 1 << 20) return (b / 1024.0).ToString("0.0") + " KB";
            if (b < 1 << 30) return (b / 1048576.0).ToString("0.0") + " MB";
            return (b / 1073741824.0).ToString("0.00") + " GB";
        }

        void Go(string path) {
            List<AdbSync.Entry> entries = null;
            try {
                using (var adb = Adb.Connect(st.AdbPort, 15000))
                using (var sync = new AdbSync(adb)) entries = sync.List(path);
            } catch (Exception e) { Program.Error("Could not open " + path + " in Android:\n" + e.Message); return; }
            dir = path;
            pathBox.Text = "Android: " + path;
            upBtn.Enabled = path != Root;
            list.BeginUpdate();
            list.Items.Clear();
            foreach (var en in entries.OrderBy(x => !x.IsDir).ThenBy(x => x.Name, StringComparer.OrdinalIgnoreCase)) {
                var it = new ListViewItem(en.Name, en.IsDir ? "dir" : "file") { Tag = en };
                it.SubItems.Add(en.IsDir ? "" : Human(en.Size));
                it.SubItems.Add(en.Modified.ToString("g"));
                list.Items.Add(it);
            }
            list.EndUpdate();
        }

        void PickAndSend() {
            using (var d = new OpenFileDialog { Title = "Send files to Android (" + dir + ")", Multiselect = true }) {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                SendToAndroid(vm, st, d.FileNames, dir);
                Go(dir);
            }
        }

        // Sends files and folders from Windows to an Android folder, then asks Android's media
        // scanner to index them (so videos/music/photos appear in VLC and gallery apps).
        public static void SendToAndroid(Vm vm, VmState st, string[] paths, string remoteDir) {
            var jobs = new List<KeyValuePair<string, string>>();       // local file -> remote path
            var dirs = new List<string>();
            foreach (var p in paths) {
                if (Directory.Exists(p)) {
                    string baseRemote = Join(remoteDir, Path.GetFileName(p.TrimEnd('\\')));
                    dirs.Add(baseRemote);
                    foreach (var f in Directory.GetFiles(p, "*", SearchOption.AllDirectories)) {
                        string rel = f.Substring(p.TrimEnd('\\').Length + 1).Replace('\\', '/');
                        jobs.Add(new KeyValuePair<string, string>(f, Join(baseRemote, rel)));
                        dirs.Add(Parent2(Join(baseRemote, rel)));
                    }
                } else if (File.Exists(p)) jobs.Add(new KeyValuePair<string, string>(p, Join(remoteDir, Path.GetFileName(p))));
            }
            if (jobs.Count == 0) return;
            long total = jobs.Sum(j => new FileInfo(j.Key).Length), done = 0;
            string error = null;
            Program.RunWithStatus("Sending to Android...", status => {
                using (var adb = Adb.Connect(st.AdbPort, 60000)) {
                    if (dirs.Count > 0) adb.Shell("mkdir -p " + string.Join(" ", dirs.Distinct().Select(Adb.Sh)));
                    using (var sync = new AdbSync(adb)) {
                        int i = 0;
                        foreach (var j in jobs) {
                            i++;
                            long before = done;
                            string name = Path.GetFileName(j.Key);
                            try {
                                sync.Push(j.Key, j.Value, (sent, size) => status(string.Format("Sending {0}/{1}: {2}  ({3}%)", i, jobs.Count, name,
                                    total == 0 ? 100 : (before + sent) * 100 / total)));
                            } catch (Exception e) { error = name + ": " + e.Message; return false; }
                            done += new FileInfo(j.Key).Length;
                        }
                    }
                    status("Updating Android's media library...");
                    foreach (var j in jobs.Take(200))
                        adb.Shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d " + Adb.Sh("file://" + Uri.EscapeUriString(j.Value)) + " >/dev/null");
                }
                return true;
            });
            vm.Log("sent " + jobs.Count + " file(s) to " + remoteDir + (error != null ? " (error: " + error + ")" : ""));
            if (error != null) Program.Error("Could not send " + error);
        }

        static string Parent2(string p) { int i = p.LastIndexOf('/'); return i <= 0 ? "/" : p.Substring(0, i); }

        void OpenSelected() { var l = Selected().ToList(); if (l.Count > 0 && l[0].IsDir) Go(Join(dir, l[0].Name)); }

        // Copies the selected Android files/folders into a Windows folder; returns (count, error).
        KeyValuePair<int, string> CopyToWindows(List<AdbSync.Entry> sel, string target) {
            string error = null; int count = 0;
            Program.RunWithStatus("Copying to Windows...", status => {
                using (var adb = Adb.Connect(st.AdbPort, 60000))
                using (var sync = new AdbSync(adb)) {
                    var queue = new Queue<KeyValuePair<string, AdbSync.Entry>>();
                    var localOf = new Dictionary<string, string>();
                    foreach (var e in sel) { string rp = Join(dir, e.Name); queue.Enqueue(new KeyValuePair<string, AdbSync.Entry>(rp, e)); localOf[rp] = Path.Combine(target, e.Name); }
                    while (queue.Count > 0) {
                        var q = queue.Dequeue();
                        string local = localOf[q.Key];
                        try {
                            if (q.Value.IsDir) {
                                Directory.CreateDirectory(local);
                                foreach (var c in sync.List(q.Key)) {
                                    string rp = Join(q.Key, c.Name);
                                    queue.Enqueue(new KeyValuePair<string, AdbSync.Entry>(rp, c)); localOf[rp] = Path.Combine(local, c.Name);
                                }
                            } else {
                                string name = q.Value.Name;
                                sync.Pull(q.Key, local, q.Value.Size, (got, size) => status(string.Format("Copying {0}  ({1}%)", name, size == 0 ? 100 : got * 100 / size)));
                                count++;
                            }
                        } catch (Exception e) { error = q.Value.Name + ": " + e.Message; return false; }
                    }
                }
                return true;
            });
            vm.Log("copied " + count + " file(s) to " + target);
            return new KeyValuePair<int, string>(count, error);
        }

        string[] DownloadSelectedToTemp() {
            var sel = Selected().ToList();
            if (sel.Count == 0) return null;
            string tmp = Path.Combine(Path.GetTempPath(), "SlightDroid-files", DateTime.Now.ToString("yyyyMMdd-HHmmss-fff"));
            Directory.CreateDirectory(tmp);
            var r = CopyToWindows(sel, tmp);
            if (r.Value != null) { Program.Error("Could not copy " + r.Value); return null; }
            return sel.Select(e => Path.Combine(tmp, e.Name)).ToArray();
        }

        void CopyToClipboard() {
            var files = DownloadSelectedToTemp();
            if (files == null) return;
            var sc = new System.Collections.Specialized.StringCollection(); sc.AddRange(files);
            Clipboard.SetFileDropList(sc);
        }

        void PasteFromClipboard() {
            if (!Clipboard.ContainsFileDropList()) { MessageBox.Show(this, "Copy files in Windows Explorer first (Ctrl+C), then paste them here.", "SlightDroid"); return; }
            var f = Clipboard.GetFileDropList().Cast<string>().ToArray();
            SendToAndroid(vm, st, f, dir); Go(dir);
        }

        void RenameSelected() {
            var l = Selected().ToList(); if (l.Count == 0) return; var it = l[0];
            string name = Prompt("New name:", it.Name);
            if (string.IsNullOrEmpty(name) || name == it.Name || name.Contains("/")) return;
            try { using (var adb = Adb.Connect(st.AdbPort, 15000)) adb.Shell("mv " + Adb.Sh(Join(dir, it.Name)) + " " + Adb.Sh(Join(dir, name))); } catch (Exception e) { Program.Error(e.Message); }
            Go(dir);
        }

        void SaveSelected() {            var sel = Selected().ToList();
            if (sel.Count == 0) { MessageBox.Show(this, "Select the files or folders to copy to Windows first.", "SlightDroid"); return; }
            string target;
            using (var d = new FolderBrowserDialog { Description = "Copy the selected Android files to this Windows folder:", ShowNewFolderButton = true }) {
                d.SelectedPath = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
                if (d.ShowDialog(this) != DialogResult.OK) return;
                target = d.SelectedPath;
            }
            var r = CopyToWindows(sel, target);
            if (r.Value != null) Program.Error("Could not copy " + r.Value);
            else if (MessageBox.Show(this, r.Key + " file(s) copied to\n" + target + "\n\nOpen the folder?", "SlightDroid", MessageBoxButtons.YesNo) == DialogResult.Yes)
                System.Diagnostics.Process.Start("explorer.exe", "\"" + target + "\"");
        }
        void NewFolder() {
            string name = Prompt("New folder name:", "New folder");
            if (string.IsNullOrEmpty(name) || name.Contains("/")) return;
            try { using (var adb = Adb.Connect(st.AdbPort, 15000)) adb.Shell("mkdir -p " + Adb.Sh(Join(dir, name))); } catch (Exception e) { Program.Error(e.Message); }
            Go(dir);
        }

        void DeleteSelected() {
            var sel = Selected().ToList();
            if (sel.Count == 0) return;
            if (MessageBox.Show(this, "Delete " + sel.Count + " item(s) from Android? This cannot be undone.", "SlightDroid",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            try {
                using (var adb = Adb.Connect(st.AdbPort, 30000))
                    adb.Shell("rm -rf " + string.Join(" ", sel.Select(e => Adb.Sh(Join(dir, e.Name)))));
            } catch (Exception e) { Program.Error(e.Message); }
            Go(dir);
        }

        string Prompt(string label, string value) {
            using (var f = new Form { Text = "SlightDroid", FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
                                      MinimizeBox = false, MaximizeBox = false, ClientSize = Scale(new Size(360, 110)), Font = Font }) {
                var l = new Label { Text = label, Left = 12, Top = 12, AutoSize = true };
                var t = new TextBox { Text = value, Left = 12, Top = Scale(new Size(0, 36)).Height, Width = f.ClientSize.Width - 24 };
                var ok = new Button { Text = "OK", DialogResult = DialogResult.OK, Left = f.ClientSize.Width - Scale(new Size(180, 0)).Width, Top = Scale(new Size(0, 72)).Height, AutoSize = true };
                var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Left = f.ClientSize.Width - Scale(new Size(92, 0)).Width, Top = ok.Top, AutoSize = true };
                f.Controls.AddRange(new Control[] { l, t, ok, cancel }); f.AcceptButton = ok; f.CancelButton = cancel;
                return f.ShowDialog(this) == DialogResult.OK ? t.Text.Trim() : null;
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHFILEINFO { public IntPtr hIcon; public int iIcon; public uint attr; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string name; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string type; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SHGetFileInfo(string path, uint attr, ref SHFILEINFO fi, uint size, uint flags);

        static Icon ShellIcon(bool folder) {
            var fi = new SHFILEINFO();
            SHGetFileInfo(folder ? "folder" : "file.bin", folder ? 0x10u : 0x80u, ref fi, (uint)Marshal.SizeOf(fi), 0x100 | 0x1 | 0x10 /* ICON|SMALLICON|USEFILEATTRIBUTES */);
            return fi.hIcon != IntPtr.Zero ? Icon.FromHandle(fi.hIcon) : SystemIcons.Application;
        }
    }
}
