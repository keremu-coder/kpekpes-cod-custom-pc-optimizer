@echo off
title Kpekpes COD Custom PC Optimizer
color 0A

:: ============================================================
::  Kpekpes COD Custom PC Optimizer - launcher
::  Opens the menu in an Administrator PowerShell window.
::  Nothing is changed on your PC until you pick an option.
:: ============================================================

set "SRC=%~dp0"

if not exist "%SRC%Kpekpes.ps1" (
    echo [ERROR] Kpekpes.ps1 was not found next to this file.
    echo Extract the whole folder first, then run this launcher again.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%SRC%Kpekpes.ps1\"'"
exit /b 0
