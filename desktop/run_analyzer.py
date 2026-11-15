"""Entry point for PyInstaller and for running from source: python run_analyzer.py [files]"""
import sys

from analyzer.app import main

if __name__ == "__main__":
    sys.exit(main())
