using namespace System.Threading
using namespace System.Io

class PSMonitor
{
   hidden $_filePaths = [hashtable]::Synchronized(@{})
   hidden $_rwlock = [ReaderWriterLockSlim]::New()
   hidden $_watchedPath = ''
   hidden $_watcher = (New-Object System.IO.FileSystemWatcher)
   hidden $_processTimer = (New-Object System.Timers.Timer)

   PSMonitor([String]$watchedPath)
    { 
        $this._watchedPath = $watchedPath;

        $this.InitFileSystemWatcher();
    }

    hidden [void]InitFileSystemWatcher()
    {
        # Set FileSystemWatcher properties
        $this._watcher.Filter = "*.bak"
        $this._watcher.Path  = $this._watchedPath
        $this._watcher.IncludeSubdirectories = $true
        $this._watcher.EnableRaisingEvents = $true;

        # Get Variables ready which we need to pass into the action scriptblock
        $messageData = @{
            _processTimer = $this._processTimer
            _filePaths = $this._filePaths
            _rwlock = $this._rwlock
        }
      
        # Set timer properties
        $this._processTimer.Interval = 1000
        $this._processTimer.AutoReset = $false

        # Register Event handlers
        $_watcherEventHandler = Register-ObjectEvent -InputObject $this._watcher -EventName Created -Action $this.Watcher_FileCreated -SourceIdentifier "FSCreate_$(($this._watchedPath -split '\\')[-1])" -MessageData $messageData
        $_timerEventHandler = Register-ObjectEvent -InputObject $this._processTimer -EventName Elapsed -Action $this.ProcessQueue -SourceIdentifier "FSTick_$(($this._watchedPath -split '\\')[-1])" -MessageData $messageData
    }

    # this scriptblock gets called when a file is created
    hidden $Watcher_FileCreated = 
    {
        # pull vars from event/message data
        $eventDetails = $event.SourceEventArgs
        $_rwlock = $event.MessageData._rwlock
        $_processTimer = $event.MessageData._processTimer
        $_filePaths = $event.MessageData._filePaths

        try
        {
            $_rwlock.EnterWriteLock();
            $_filePaths.Add($eventDetails.Name,$eventDetails.FullPath);
          
            if ( -Not $_processTimer.Enabled ) {
                #First file, start timer.
                $_processTimer.Start();
            }
            else {
                #Subsequent file, reset timer.
                $_processTimer.Stop();
                $_processTimer.Start();
            }
        }
        catch{
            Write-Host $_
        }
        finally
        {
            $_rwlock.ExitWriteLock();
        }
    }

    # this scriptblock runs whenever the timer elapses
    hidden $ProcessQueue =
    {
        # pull vars from message data
        $_rwlock = $event.MessageData._rwlock
        $_processTimer = $event.MessageData._processTimer
        $_filePaths = $event.MessageData._filePaths
      
        try
        {
            $_rwlock.EnterReadLock();

            $_dupFilePaths = $_filePaths.Clone()

            $_filePaths.Clear();

            $messageData = @{
                _filePaths = $_dupFilePaths
            }
         
            # Add event to queue with the new files we picked up
            # Get-Event -SourceID PSMonitor.QueuedItem to view the event and file's that were created
            [void] (New-Event -SourceID "PSMonitor.QueuedItem" -Sender 'Timers.Timer' -MessageData $messageData)
        }
        finally
        {
            if ($_processTimer.Enabled) {
                $_processTimer.Stop();
            }
            $_rwlock.ExitReadLock();
        }
    }

    [void]Dispose()
    {
        $FSCreate_Name = "FSCreate_$(($this._watchedPath -split '\\')[-1])"
        $FSTick_Name = "FSTick_$(($this._watchedPath -split '\\')[-1])"
        Unregister-Event -SourceIdentifier $FSCreate_Name
        Unregister-Event -SourceIdentifier $FSTick_Name
        [void](Stop-Job -Name $FSCreate_Name) 
        [void](Stop-Job -Name $FSTick_Name)
        [void](Remove-Job -Name $FSCreate_Name)
        [void](Remove-Job -Name $FSTick_Name)
        if ($this._rwlock) {
            $this._rwlock.Dispose();
            $this._rwlock = $null;
        }
        if ($this._watcher) {
            $this._watcher.EnableRaisingEvents = $false;
            $this._watcher.Dispose();
            $this._watcher = $null;
        }
    }  
}