{-# LANGUAGE CPP #-}
module Cabal
  ( getPackageGhcOpts
  , findCabalFile
  ) where

#ifdef ENABLE_CABAL

import Stack
import Control.Exception (IOException, catch)
import Control.Monad (when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (execStateT, modify)
import Data.Char (isSpace)
import Data.List (foldl', nub, sort, find, isPrefixOf, isSuffixOf)
#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>))
import Data.Monoid (Monoid(..))
#endif
import Distribution.Package (PackageIdentifier(..), PackageName)
import Distribution.PackageDescription (PackageDescription(..), Executable(..), TestSuite(..), Benchmark(..), emptyHookedBuildInfo, buildable, libBuildInfo)
import Distribution.PackageDescription.Parse (readPackageDescription)
import Distribution.Simple.Configure (configure)
import Distribution.Simple.LocalBuildInfo (LocalBuildInfo(..), ComponentLocalBuildInfo(..),
    Component(..), ComponentName(..),
#if !MIN_VERSION_Cabal(1,18,0)
    allComponentsBy,
#endif
    componentBuildInfo, foldComponent)
import Distribution.Simple.Compiler (PackageDB(..))
import Distribution.Simple.Command (CommandParse(..), commandParseArgs)
import Distribution.Simple.GHC (componentGhcOptions)
import Distribution.Simple.Program (defaultProgramConfiguration)
import Distribution.Simple.Program.Db (lookupProgram)
import Distribution.Simple.Program.Types (ConfiguredProgram(programVersion), simpleProgram)
import Distribution.Simple.Program.GHC (GhcOptions(..), renderGhcOptions)
import Distribution.Simple.Setup (ConfigFlags(..), defaultConfigFlags, configureCommand, toFlag)
#if MIN_VERSION_Cabal(1,21,1)
import Distribution.Utils.NubList
#endif
import qualified Distribution.Simple.GHC as GHC(configure)
import Distribution.Verbosity (silent)
import Distribution.Version (Version(..))

import System.IO.Error (ioeGetErrorString)
import System.Directory (doesFileExist, doesDirectoryExist, getDirectoryContents)
import System.FilePath (takeDirectory, splitFileName, (</>))


componentName :: Component -> ComponentName
componentName =
    foldComponent (const CLibName)
                  (CExeName . exeName)
                  (CTestName . testName)
                  (CBenchName . benchmarkName)

getComponentLocalBuildInfo :: LocalBuildInfo -> ComponentName -> ComponentLocalBuildInfo
#if MIN_VERSION_Cabal(1,18,0)
getComponentLocalBuildInfo lbi cname = getLocalBuildInfo cname $ componentsConfigs lbi
    where getLocalBuildInfo cname' ((cname'', clbi, _):cfgs) =
            if cname' == cname'' then clbi else getLocalBuildInfo cname' cfgs
          getLocalBuildInfo _ [] = error $ "internal error: missing config"
#else
getComponentLocalBuildInfo lbi CLibName =
    case libraryConfig lbi of
        Nothing -> error $ "internal error: missing library config"
        Just clbi -> clbi
getComponentLocalBuildInfo lbi (CExeName name) =
    case lookup name (executableConfigs lbi) of
        Nothing -> error $ "internal error: missing config for executable " ++ name
        Just clbi -> clbi
getComponentLocalBuildInfo lbi (CTestName name) =
    case lookup name (testSuiteConfigs lbi) of
        Nothing -> error $ "internal error: missing config for test suite " ++ name
        Just clbi -> clbi
getComponentLocalBuildInfo lbi (CBenchName name) =
    case lookup name (testSuiteConfigs lbi) of
        Nothing -> error $ "internal error: missing config for benchmark " ++ name
        Just clbi -> clbi
#endif

#if MIN_VERSION_Cabal(1,18,0)
-- TODO: Fix callsites so we don't need `allComponentsBy`. It was taken from
-- http://hackage.haskell.org/package/Cabal-1.16.0.3/docs/src/Distribution-Simple-LocalBuildInfo.html#allComponentsBy
-- since it doesn't exist in Cabal 1.18.*
--
-- | Obtains all components (libs, exes, or test suites), transformed by the
-- given function.  Useful for gathering dependencies with component context.
allComponentsBy :: PackageDescription
                -> (Component -> a)
                -> [a]
allComponentsBy pkg_descr f =
    [ f (CLib  lib) | Just lib <- [library pkg_descr]
                    , buildable (libBuildInfo lib) ]
 ++ [ f (CExe  exe) | exe <- executables pkg_descr
                    , buildable (buildInfo exe) ]
 ++ [ f (CTest tst) | tst <- testSuites pkg_descr
                    , buildable (testBuildInfo tst)
                    , testEnabled tst ]
 ++ [ f (CBench bm) | bm <- benchmarks pkg_descr
                    , buildable (benchmarkBuildInfo bm)
                    , benchmarkEnabled bm ]
#endif

stackifyFlags :: ConfigFlags -> Maybe StackConfig -> ConfigFlags
stackifyFlags cfg Nothing   = cfg
stackifyFlags cfg (Just si) = cfg { configHcPath = toFlag ghc
                                  , configHcPkg = toFlag ghcPkg
                                  , configDistPref    = toFlag dist
                                  , configPackageDBs  = pdbs
                                  }
    where
      pdbs                  = [Nothing, Just GlobalPackageDB] ++ pdbs'
      pdbs'                 = Just . SpecificPackageDB <$> stackDbs si
      dist                  = stackDist si
      ghc = stackGhcBinDir si </> "ghc"
      ghcPkg = stackGhcBinDir si </> "ghc-pkg"

-- via: https://groups.google.com/d/msg/haskell-stack/8HJ6DHAinU0/J68U6AXTsasJ
-- cabal configure --package-db=clear --package-db=global --package-db=$(stack path --snapshot-pkg-db) --package-db=$(stack path --local-pkg-db)

getPackageGhcOpts :: FilePath -> Maybe StackConfig -> [String] -> IO (Either String [String])
getPackageGhcOpts path mbStack opts = do
    getPackageGhcOpts' `catch` (\e -> do
        return $ Left $ "Cabal error: " ++ (ioeGetErrorString (e :: IOException)))
  where
    getPackageGhcOpts' :: IO (Either String [String])
    getPackageGhcOpts' = do
        genPkgDescr <- readPackageDescription silent path
        distDir     <- getDistDir

        let programCfg = defaultProgramConfiguration
        let initCfgFlags = (defaultConfigFlags programCfg)
                             { configDistPref = toFlag distDir
                             -- TODO: figure out how to find out this flag
                             , configUserInstall = toFlag True

                             -- configure with --enable-tests to include test dependencies/modules
                             , configTests = toFlag True

                             -- configure with --enable-benchmarks to include benchmark dependencies/modules
                             , configBenchmarks = toFlag True
                             }
        let initCfgFlags' = stackifyFlags initCfgFlags mbStack

        cfgFlags <- flip execStateT initCfgFlags' $ do
          let sandboxConfig = takeDirectory path </> "cabal.sandbox.config"

          exists <- lift $ doesFileExist sandboxConfig
          when (exists) $ do
            sandboxPackageDb <- lift $ getSandboxPackageDB sandboxConfig
            modify $ \x -> x { configPackageDBs = [Just sandboxPackageDb] }

          let cmdUI = configureCommand programCfg
          case commandParseArgs cmdUI True opts of
            CommandReadyToGo (modFlags, _) -> modify modFlags
            CommandErrors (e:_) -> error e
            _ -> return ()

        localBuildInfo <- configure (genPkgDescr, emptyHookedBuildInfo) cfgFlags
        let pkgDescr = localPkgDescr localBuildInfo
        let baseDir = fst . splitFileName $ path
        case getGhcVersion localBuildInfo  of
            Nothing -> return $ Left "GHC is not configured"
            Just ghcVersion  -> do
                let mbLibName = pkgLibName pkgDescr
                let ghcOpts' = foldl' mappend mempty . map (getComponentGhcOptions localBuildInfo) .
                               flip allComponentsBy (\c -> c) . localPkgDescr $ localBuildInfo
                    -- FIX bug in GhcOptions' `mappend`
#if MIN_VERSION_Cabal(1,21,1)
-- API Change:
-- Distribution.Simple.Program.GHC.GhcOptions now uses NubListR's
--  GhcOptions { .. ghcOptPackages :: NubListR (InstalledPackageId, PackageId, ModuleRemaining) .. }
                    ghcOpts = ghcOpts' { ghcOptExtra = overNubListR (filter (/= "-Werror")) $ ghcOptExtra ghcOpts'
#if __GLASGOW_HASKELL__ >= 709
                                       , ghcOptPackageDBs = sort $ nub (ghcOptPackageDBs ghcOpts')
#endif
                                       , ghcOptPackages = overNubListR (filter (\(_, pkgId, _) -> Just (pkgName pkgId) /= mbLibName)) $ (ghcOptPackages ghcOpts')
                                       , ghcOptSourcePath = overNubListR (map (baseDir </>)) (ghcOptSourcePath ghcOpts')
                                       }
#else
--  GhcOptions { .. ghcOptPackages :: [(InstalledPackageId, PackageId)]  .. }
                let ghcOpts = ghcOpts' { ghcOptExtra = filter (/= "-Werror") $ nub $ ghcOptExtra ghcOpts'
                                       , ghcOptPackages = filter (\(_, pkgId) -> Just (pkgName pkgId) /= mbLibName) $ nub (ghcOptPackages ghcOpts')
                                       , ghcOptSourcePath = map (baseDir </>) (ghcOptSourcePath ghcOpts')
                                       }
#endif

#if MIN_VERSION_Cabal(1,18,0)
-- API Change:
-- Distribution.Simple.GHC.configure now returns (Compiler, Maybe Platform, ProgramConfiguration) 
-- It used to just return (Compiler, ProgramConfiguration)
-- GHC.configure :: Verbosity -> Maybe FilePath -> Maybe FilePath -> ProgramConfiguration
--               -> IO (Compiler, Maybe Platform, ProgramConfiguration)
                (ghcInfo, mbPlatform, _) <- GHC.configure silent Nothing Nothing defaultProgramConfiguration
#else
-- configure :: Verbosity -> Maybe FilePath -> Maybe FilePath -> ProgramConfiguration
--           -> IO (Compiler, ProgramConfiguration)
                (ghcInfo, _) <- GHC.configure silent Nothing Nothing defaultProgramConfiguration
                -- let mbPlatform = Just (hostPlatform localBuildInfo) :: Maybe Platform
#endif
                putStrLn $ "Configured GHC " ++ show ghcVersion
#if MIN_VERSION_Cabal(1,18,0)
                                             ++ " " ++ show mbPlatform
#endif
#if MIN_VERSION_Cabal(1,23,2)
-- API Change:
-- Distribution.Simple.Program.GHC.renderGhcOptions now takes Platform argument
-- renderGhcOptions :: Compiler -> Platform -> GhcOptions -> [String]
                return $ case mbPlatform of
                    Just platform -> Right $ renderGhcOptions ghcInfo platform ghcOpts
                    Nothing       -> Left "GHC.configure did not return platform"
#else
#if MIN_VERSION_Cabal(1,20,0)
-- renderGhcOptions :: Compiler -> GhcOptions -> [String]
                return $ Right $ renderGhcOptions ghcInfo ghcOpts
#else
-- renderGhcOptions :: Version -> GhcOptions -> [String]
                return $ Right $ renderGhcOptions ghcVersion ghcOpts
#endif
#endif

    -- returns the right 'dist' directory in the case of a sandbox
    getDistDir = do
        let dir = takeDirectory path </> "dist"
        exists <- doesDirectoryExist dir
        if not exists then return dir else do
            contents <- getDirectoryContents dir
            return . maybe dir (dir </>) $ find ("dist-sandbox-" `isPrefixOf`) contents

pkgLibName :: PackageDescription -> Maybe PackageName
pkgLibName pkgDescr = if hasLibrary pkgDescr
                      then Just $ pkgName . package $ pkgDescr
                      else Nothing

hasLibrary :: PackageDescription -> Bool
hasLibrary = maybe False (\_ -> True) . library

getComponentGhcOptions :: LocalBuildInfo -> Component -> GhcOptions
getComponentGhcOptions lbi comp =
    componentGhcOptions silent lbi bi clbi (buildDir lbi)

  where bi   = componentBuildInfo comp
        clbi = getComponentLocalBuildInfo lbi (componentName comp)

getGhcVersion :: LocalBuildInfo -> Maybe Version
getGhcVersion lbi = let db = withPrograms lbi
                     in do ghc <- lookupProgram (simpleProgram "ghc") db
                           programVersion ghc

getSandboxPackageDB :: FilePath -> IO PackageDB
getSandboxPackageDB sandboxPath = do
    contents <- readFile sandboxPath
    return $ SpecificPackageDB $ extractValue . parse $ contents
  where
    pkgDbKey = "package-db:"
    parse = head . filter (pkgDbKey `isPrefixOf`) . lines
    extractValue = fst . break (`elem` "\n\r") . dropWhile isSpace . drop (length pkgDbKey)


findCabalFile :: FilePath -> IO (Maybe FilePath)
findCabalFile dir = do
    allFiles <- getDirectoryContents dir
    let mbCabalFile = find (isCabalFile) allFiles
    case mbCabalFile of
      Just cabalFile -> return $ Just $ dir </> cabalFile
      Nothing ->
        let parentDir = takeDirectory dir
         in if parentDir == dir
            then return Nothing
            else findCabalFile parentDir

  where

    isCabalFile :: FilePath -> Bool
    isCabalFile path = ".cabal" `isSuffixOf` path
                    && length path > length ".cabal"

#else
import Stack

getPackageGhcOpts :: FilePath -> Maybe StackConfig -> [String] -> IO (Either String [String])
getPackageGhcOpts _ _ _ = return $ Right []

findCabalFile :: FilePath -> IO (Maybe FilePath)
findCabalFile _ = return Nothing

#endif
