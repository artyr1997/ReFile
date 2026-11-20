# ReFile (Swift)

ReFile rewritten as a native Mac app (AppKit, AVFoundation, PDFKit; no web view but for an EPUB's pages).
FILE, TEXT, VIEW (pictures, PDF, EPUB, CBZ / CBR) and PLAY (the music library, the radio, videos). It keeps
what it kept before: RePlay's library (Application Support/com.artursavytskyi.resound), and, brought over once
from the old app's storage, the mode, the order and where each book was left.

    ./build.sh            # build/ReFile.app
    ./build.sh --install  # into /Applications/ReSpace
    build/ReFile.app/Contents/MacOS/ReFile --render <dir>   # its views as pictures, over made-up files
