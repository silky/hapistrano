{-# LANGUAGE OverloadedStrings #-}

-- | A module for easily creating reliable deploy processes for Haskell
-- applications.
module System.Hapistrano
       ( Config(..)

       , activateRelease
       , currentPath
       , defaultSuccessHandler
       , defaultErrorHandler
       , directoryExists
       , isReleaseString
       , pathToRelease
       , pushRelease
       , readCurrentLink
       , restartServerCommand
       , rollback
       , runRC
       , runBuild

       ) where

import Control.Monad.Reader (ReaderT(..), ask)

import System.Hapistrano.Types (
  Config(..), Hapistrano, Release, ReleaseFormat(..))

import Control.Monad (unless, void)
import System.Exit (ExitCode(..), exitWith)

import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Either ( left
                                  , right
                                  , eitherT )

import Data.Char (isNumber)
import Data.List (intercalate, sortBy, isInfixOf)
import Data.Time (getCurrentTime)
import Data.Time.Format (formatTime)
import System.FilePath.Posix (joinPath, splitPath)
import System.IO (hPutStrLn, stderr)
import System.Locale (defaultTimeLocale)
import System.Process (readProcessWithExitCode)

-- | Does basic project setup for a project, including making sure
-- some directories exist, and pushing a new release directory with the
-- SHA1 or branch specified in the configuration.
pushRelease :: Hapistrano (Maybe Release)
pushRelease = setupDirs >> ensureRepositoryPushed >> updateCacheRepo >>
              cleanReleases >> cloneToRelease >>= setReleaseRevision

-- | Switches the current symlink to point to the release specified in
-- the configuration. Maybe used in either deploy or rollback cases.
activateRelease :: Maybe Release -> Hapistrano (Maybe String)
activateRelease rel = removeCurrentSymlink >> symlinkCurrent rel

-- | Given a pair of actions, one to perform in case of failure, and
-- one to perform in case of success, run an EitherT and get back a
-- monadic result.
runRC :: ((Int, String) -> ReaderT Config IO a) -- ^ Error handler
      -> (a -> ReaderT Config IO a)             -- ^ Success handler
      -> Config                  -- ^ Hapistrano deployment configuration
      -> Hapistrano a            -- ^ The remote command to run
      -> IO a
runRC errorHandler successHandler config command =
    runReaderT (eitherT errorHandler successHandler command) config

-- | Default method to run on deploy failure. Emits a failure message
-- and exits with a status code of 1.
defaultErrorHandler :: a -> ReaderT Config IO ()
defaultErrorHandler _ =
  liftIO $ hPutStrLn stderr "Deploy failed." >> exitWith (ExitFailure 1)

-- | Default method to run on deploy success.
defaultSuccessHandler :: a -> ReaderT Config IO ()
defaultSuccessHandler _ =
  liftIO $ putStrLn "Deploy completed successfully."


-- | Creates necessary directories for the hapistrano project. Should
-- only need to run the first time the project is deployed on a given
-- system.
setupDirs :: Hapistrano ()
setupDirs = do
  conf <- ask

  mapM_ (runCommand (host conf))
    ["mkdir -p " ++ releasesPath conf, "mkdir -p " ++ cacheRepoPath conf]

directoryExists :: Maybe String -> FilePath -> IO Bool
directoryExists hst path = do
  let (command, args) = case hst of
        Just h  -> ("ssh", [h, "ls", path])
        Nothing -> ("ls", [path])

  (code, _, _) <- readProcessWithExitCode command args ""

  return $ case code of
    ExitSuccess   -> True
    ExitFailure _ -> False

-- | Runs the given command either locally or on the local machine.
runCommand :: Maybe String -- ^ The host on which to run the command
           -> String -- ^ The command to run, either on the local or remote host
           -> Hapistrano (Maybe String)

runCommand Nothing command = do
  liftIO $ putStrLn $ "Going to execute " ++ command ++ " locally."

  let (cmd, args) = (head (words command), tail (words command))

  (code, stdout, err) <- liftIO $ readProcessWithExitCode cmd args ""

  case code of
    ExitSuccess -> do
      unless (null stdout) (liftIO $ putStrLn $ "Output:\n" ++ stdout)

      right $ maybeString stdout

    ExitFailure int -> left (int, err)

runCommand (Just server) command = do
  liftIO $ putStrLn $ "Going to execute " ++ command ++ " on host " ++ server
           ++ "."

  (code, stdout, err) <-
    liftIO $ readProcessWithExitCode "ssh" (server : words command) ""

  case code of
    ExitSuccess -> do
      liftIO $ putStrLn $ "Command '" ++ command ++
        "' was successful on host '" ++ server ++ "'."

      unless (null stdout) (liftIO $ putStrLn $ "Output:\n" ++ stdout)

      right $ maybeString stdout

    ExitFailure int -> left (int, err)


-- | Returns a timestamp in the default format for build directories.
currentTimestamp :: ReleaseFormat -> IO String
currentTimestamp format = do
  curTime <- getCurrentTime
  return $ formatTime defaultTimeLocale fstring curTime

  where fstring = case format of
          Short -> "%Y%m%d%H%M%S"
          Long  -> "%Y%m%d%H%M%S%q"

echoMessage :: String -> Hapistrano (Maybe String)
echoMessage msg = do
  liftIO $ putStrLn msg
  right Nothing

-- | Returns the FilePath pointed to by the current symlink.
readCurrentLink :: Maybe String -> FilePath -> IO FilePath
readCurrentLink hst path = do
  let (command, args) = case hst of
        Just h  -> ("ssh", [h, "readlink", path])
        Nothing -> ("readlink", [path])

  (code, stdout, _) <- readProcessWithExitCode command args ""

  case (code, stdout) of
    (ExitSuccess, out) -> return $ trim out
    (ExitFailure _, _) -> error "Unable to read current symlink"

  where trim = reverse . dropWhile (=='\n') . reverse

-- | Ensure that the initial bare repo exists in the repo directory. Idempotent.
ensureRepositoryPushed :: Hapistrano (Maybe String)
ensureRepositoryPushed = do
  conf <- ask
  res  <-
    liftIO $ directoryExists (host conf) $ joinPath [cacheRepoPath conf, "refs"]

  if res
    then right $ Just "Repo already existed"
    else createCacheRepo

-- | Returns a Just String or Nothing based on whether the input is null or
-- has contents.
maybeString :: String -> Maybe String
maybeString possibleString =
  if null possibleString then Nothing else Just possibleString

-- | Returns the full path of the folder containing all of the release builds.
releasesPath :: Config -> FilePath
releasesPath conf = joinPath [deployPath conf, "releases"]

-- | Figures out the most recent release if possible, and sets the
-- StateT monad with the correct timestamp. This function is used
-- before rollbacks.
detectPrevious :: [String] -> Hapistrano (Maybe String)
detectPrevious rs =
  case biggest rs of
    Nothing -> left (1, "No previous releases detected")
    Just rls -> right $ Just rls

-- | Activates the previous detected release.
rollback :: Hapistrano (Maybe String)
rollback = previousReleases >>= detectPrevious >>= activateRelease

-- | Clones the repository to the next releasePath timestamp. Makes a new
-- timestamp if one doesn't yet exist in the HapistranoState. Returns the
-- timestamp of the release that we cloned to.
cloneToRelease :: Hapistrano (Maybe String)
cloneToRelease = do
  conf <- ask
  rls  <- liftIO $ currentTimestamp (releaseFormat conf)

  void $ runCommand (host conf) $ "git clone " ++ cacheRepoPath conf ++
    " " ++ joinPath [ releasesPath conf, rls ]

  return $ Just rls


-- | Returns the full path to the git repo used for cache purposes on the
-- target host filesystem.
cacheRepoPath :: Config -> FilePath
cacheRepoPath conf = joinPath [deployPath conf, "repo"]

-- | Returns the full path to the current symlink.
currentPath :: FilePath -> FilePath
currentPath depPath = joinPath [depPath, "current"]

-- | Take the release timestamp from the end of a filepath.
pathToRelease :: FilePath -> Release
pathToRelease = last . splitPath

-- | Returns a list of Strings representing the currently deployed releases.
releases :: Hapistrano [Release]
releases = do
  conf <- ask
  res  <- runCommand (host conf) $ "find " ++ releasesPath conf ++
          " -type d -maxdepth 1"

  case res of
    Nothing -> right []
    Just s ->
      right $
      filter (isReleaseString (releaseFormat conf)) . map pathToRelease $
      lines s

previousReleases :: Hapistrano [Release]
previousReleases = do
  rls <- releases
  conf <- ask

  currentRelease <-
    liftIO $ readCurrentLink (host conf) (currentPath (deployPath conf))

  let currentRel = (head . lines . pathToRelease) currentRelease
  return $ filter (< currentRel) rls

releasePath :: Config -> Release -> FilePath
releasePath conf rls = joinPath [releasesPath conf, rls]

-- | Given a list of release strings, takes the last four in the sequence.
-- Assumes a list of folders that has been determined to be a proper release
-- path.
oldReleases :: Config -> [Release] -> [FilePath]
oldReleases conf rs = map mergePath toDelete
  where sorted             = sortBy (flip compare) rs
        toDelete           = drop 4 sorted
        mergePath = releasePath conf

-- | Removes releases older than the last five to avoid filling up the target
-- host filesystem.
cleanReleases :: Hapistrano (Maybe String)
cleanReleases = do
  conf        <- ask
  allReleases <- releases

  let deletable = oldReleases conf allReleases

  if null deletable
    then
      echoMessage "There are no old releases to prune."

    else
      runCommand (host conf) $
      "rm -rf -- " ++ unwords deletable

-- | Returns a Bool indicating if the given String is in the proper release
-- format.
isReleaseString :: ReleaseFormat -> String -> Bool
isReleaseString format s = all isNumber s && length s == releaseLength
  where releaseLength = case format of
          Short -> 14
          Long  -> 26

-- | Creates the git repository that is used on the target host for
-- cache purposes.
createCacheRepo :: Hapistrano (Maybe String)
createCacheRepo = do
  conf <- ask

  runCommand (host conf) $ "git clone --bare " ++ repository conf ++ " " ++
    cacheRepoPath conf

-- | Returns the full path of the symlink pointing to the current
-- release.
currentSymlinkPath :: Config -> FilePath
currentSymlinkPath conf = joinPath [deployPath conf, "current"]

currentTempSymlinkPath :: Config -> FilePath
currentTempSymlinkPath conf = joinPath [deployPath conf, "current_tmp"]

-- | Removes the current symlink in preparation for a new release being
-- activated.
removeCurrentSymlink :: Hapistrano (Maybe String)
removeCurrentSymlink = do
  conf <- ask

  runCommand (host conf) $ "rm -rf " ++ currentSymlinkPath conf

-- | Determines whether the target host OS is Linux
targetIsLinux :: Hapistrano Bool
targetIsLinux = do
  conf <- ask
  res <- runCommand (host conf) "uname"

  case res of
    Just output -> right $ "Linux" `isInfixOf` output
    _ -> left (1, "Unable to determine remote host type")

-- | Runs a command to restart a server if a command is provided.
restartServerCommand :: Hapistrano (Maybe String)
restartServerCommand = do
  conf <- ask

  case restartCommand conf of
    Nothing -> return $ Just "No command given for restart action."
    Just cmd -> runCommand (host conf) cmd

-- | Runs a build script if one is provided.
runBuild :: Maybe Release -> Hapistrano ()
runBuild rel = do
  conf <- ask

  case buildScript conf of
    Nothing ->
      liftIO $ putStrLn "No build script specified, skipping build step."

    Just scr -> do
      fl <- liftIO $ readFile scr
      buildRelease rel $ lines fl

-- | Returns the best 'mv' command for a symlink given the target platform.
mvCommand :: Bool   -- ^ Whether the target host is Linux
          -> String -- ^ The best mv command for a symlink on the platform
mvCommand True  = "mv -Tf"
mvCommand False = "mv -f"

-- | Creates a symlink to the current release.
lnCommand ::
  String    -- ^ The path of the new release
  -> String -- ^ The temporary symlink target for the release
  -> String -- ^ A command to create the temporary symlink
lnCommand rlsPath symlinkPath = unwords ["ln -s", rlsPath, symlinkPath]

-- | Creates a symlink to the directory indicated by the release timestamp.
-- hapistrano does this by creating a temporary symlink and doing an atomic
-- mv (1) operation to activate the new release.
symlinkCurrent :: Maybe Release -> Hapistrano (Maybe String)
symlinkCurrent rel = do
  conf <- ask

  case rel of
    Nothing  -> left (1, "No releases to symlink!")

    Just rls -> do
      isLnx <- targetIsLinux

      let tmpLnCmd =
            lnCommand (releasePath conf rls) (currentTempSymlinkPath conf)

      _ <- runCommand (host conf) tmpLnCmd

      runCommand (host conf) $ unwords [ mvCommand isLnx
                                       , currentTempSymlinkPath conf
                                       , currentSymlinkPath conf ]


-- | Updates the git repo used as a cache in the target host filesystem.
updateCacheRepo :: Hapistrano ()
updateCacheRepo = do
  conf <- ask

  void $ runCommand (host conf) $ intercalate " && "
    [ "cd " ++ cacheRepoPath conf
    , "git fetch origin +refs/heads/*:refs/heads/*" ]

-- | Sets the release to the correct revision by resetting the
-- head of the git repo.
setReleaseRevision :: Maybe Release -> Hapistrano (Maybe Release)
setReleaseRevision rel = do
  conf <- ask

  case rel of
    Nothing -> do
      liftIO $ putStrLn "No release path in which to set revision."
      left (1, "No release path in which to set revision.")

    Just rls -> do
      liftIO $ putStrLn "Setting revision in release path."
      void $ runCommand (host conf) $ intercalate " && "
        [ "cd " ++ releasePath conf rls
        , "git fetch --all"
        , "git reset --hard " ++ revision conf
        ]

      right rel

-- | Returns a command that builds this application. Sets the context
-- of the build by switching to the release directory before running
-- the script.
buildRelease :: Maybe Release
             -> [String] -- ^ Commands to be run. List intercalated
                         -- with "&&" so that failure aborts the
                         -- sequence.
             -> Hapistrano ()
buildRelease rel commands = do
  conf <- ask

  case rel of
    Nothing -> left (1, "No releases to symlink!")
    Just rls -> do
      let cdCmd = "cd " ++ releasePath conf rls
      void $ runCommand (host conf) $ intercalate " && " $ cdCmd : commands

-- | A safe version of the `maximum` function in Data.List.
biggest :: Ord a => [a] -> Maybe a
biggest rls =
  case sortBy (flip compare) rls of
    []  -> Nothing
    r:_ -> Just r
