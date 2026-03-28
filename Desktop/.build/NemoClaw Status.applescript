on run
  my showControls()
end run

on reopen
  my showControls()
end reopen

on showControls()
  set launcherPath to "/Users/gunnarhostetler/Documents/GitHub/NemoClaw/scripts/launch-macos.sh"
  set statusLogPath to "/Users/gunnarhostetler/.nemoclaw/logs/status-app.log"
  set promptText to "NemoClaw controls\n\nStart or reopen the dashboard, stop the UI stack, or restart it cleanly."
  set buttonChoice to button returned of (display dialog promptText buttons {"Cancel", "Stop", "Restart", "Start", "Open Dashboard"} default button "Open Dashboard" cancel button "Cancel" with title "NemoClaw Status")

  if buttonChoice is "Cancel" then
    return
  else if buttonChoice is "Stop" then
    my runAction("--app-stop", launcherPath, statusLogPath)
  else if buttonChoice is "Restart" then
    my runAction("--app-restart", launcherPath, statusLogPath)
  else if buttonChoice is "Start" then
    my runAction("--app-start", launcherPath, statusLogPath)
  else if buttonChoice is "Open Dashboard" then
    my runAction("--app-start", launcherPath, statusLogPath)
  end if
end showControls

on runAction(modeFlag, launcherPath, statusLogPath)
  set commandText to "/usr/bin/nohup /bin/bash " & quoted form of launcherPath & " " & quoted form of modeFlag & " >>" & quoted form of statusLogPath & " 2>&1 &"
  do shell script commandText
end runAction
