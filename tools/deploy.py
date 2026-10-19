"""Copy the core and MRAs to the MiSTer and optionally start an MRA.

    python tools/deploy.py [mra name to load]

Debug build (revision NAMCOS10, output_files/NAMCOS10.rbf) -> /media/fat/_Arcade/cores/Arcade-SYSTEM10_<date>.rbf
(MRA <rbf>SYSTEM10</rbf>), MRAs -> /media/fat/_Arcade/
(ROM zips are expected in /media/fat/games/mame).
"""
import ftplib
import glob
import os
import subprocess
import sys
import time

HOST, USER, PW = "192.168.77.2", "root", "1"
HOSTKEY = "SHA256:FqNJOsj3FLUoMQxgn+cqGoXvVfENmVK4QFoSCMKl2lU"
ROOT = os.path.join(os.path.dirname(__file__), "..")
PLINK = r"C:\Program Files\PuTTY\plink.exe"


def ssh(cmd):
    return subprocess.run([PLINK, "-batch", "-ssh", "-pw", PW, "-hostkey", HOSTKEY, f"{USER}@{HOST}", cmd],
                          capture_output=True, text=True, timeout=60).stdout


def main():
    rbf = os.path.join(ROOT, "output_files", "NAMCOS10.rbf")
    date = time.strftime("%Y%m%d", time.localtime(os.path.getmtime(rbf)))
    ftp = ftplib.FTP(HOST, USER, PW, timeout=60)
    ftp.cwd("/media/fat/_Arcade/cores")
    for f in ftp.nlst():
        if (f.startswith("NAMCOS10_") or f.startswith("Arcade-SYSTEM10_")) and f.endswith(".rbf"):
            ftp.delete(f)
    with open(rbf, "rb") as f:
        ftp.storbinary(f"STOR Arcade-SYSTEM10_{date}.rbf", f)
    ftp.cwd("/media/fat/_Arcade")
    for m in glob.glob(os.path.join(ROOT, "releases", "_Arcade", "*.mra")):
        with open(m, "rb") as f:
            ftp.storbinary(f"STOR {os.path.basename(m)}", f)
    ftp.quit()
    print(f"uploaded Arcade-SYSTEM10_{date}.rbf and MRAs")
    if len(sys.argv) > 1:
        print(ssh(f'echo "load_core /media/fat/_Arcade/{sys.argv[1]}" > /dev/MiSTer_cmd'))


if __name__ == "__main__":
    main()
