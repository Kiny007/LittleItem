Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptPath = fileSystem.BuildPath(fileSystem.GetParentFolderName(WScript.ScriptFullName), "DesktopTodo.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"
shell.Run command, 0, False
