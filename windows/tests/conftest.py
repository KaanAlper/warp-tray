"""windows/ dizinini sys.path'e ekler ki testler `asenaplug` paketini import edebilsin."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
