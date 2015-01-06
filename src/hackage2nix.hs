-- Run: cabal build -j hackage2nix && dist/build/hackage2nix/hackage2nix >hackage-packages.nix && mv hackage-packages.nix ~/.nix-defexpr/pkgs/development/haskell-modules/hackage-packages.nix && nix-env -qaP | tail -1

module Main ( main ) where

import Cabal2Nix.Flags ( configureCabalFlags )
import Cabal2Nix.Generate ( cabal2nix' )
import Cabal2Nix.Hackage ( readHashedHackage, Hackage )
-- import Cabal2Nix.Name
import Cabal2Nix.Package
import Control.Monad
import Control.Applicative hiding ( empty )
import Control.Monad.Par.Combinator
import Control.Monad.Par.IO
-- import Control.Monad.RWS
import Control.Monad.Trans
import Data.Map ( Map )
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid
import Data.Set ( Set )
import qualified Data.Set as Set
import Distribution.Compiler
-- import Distribution.Compiler
import Distribution.NixOS.Derivation.Cabal
import Distribution.NixOS.PackageMap ( PackageMap, readNixpkgPackageMap )
import Distribution.NixOS.PrettyPrinting hiding ( (<>) )
import Distribution.Package
import Distribution.PackageDescription hiding ( buildDepends, extraLibs, buildTools )
-- import Options.Applicative hiding ( empty )
import Distribution.PackageDescription.Configuration
import Distribution.System
import Distribution.Text
import Distribution.Version

type Nixpkgs = PackageMap       -- Map String (Set [String])
type PackageSet = Map String Version
type PackageMultiSet = Map String (Set Version)

type Constraint = Dependency

(!) :: Hackage -> String -> Map Version GenericPackageDescription
(!) hackage pkg = fromMaybe (error (show pkg ++ " is not a valid hackage package")) (Map.lookup pkg hackage)

resolveConstraint :: Constraint -> Hackage -> Version
resolveConstraint c = fromMaybe (error ("constraint " ++ display c ++ " cannot be resolved in Hackage")) .
                        resolveConstraint' c

resolveConstraint' :: Constraint -> Hackage -> Maybe Version
resolveConstraint' (Dependency (PackageName name) vrange) hackage | Set.null vs = Nothing
                                                                  | otherwise   = Just (Set.findMax vs)
  where vs = Set.filter (`withinRange` vrange) (Map.keysSet (hackage ! name))

main :: IO ()
main = do
  hackage <- readHashedHackage
  nixpkgs <- readNixpkgPackageMap
  runParIO (generatePackageSet (Map.delete "type" hackage) nixpkgs)

generatePackageSet :: Hackage -> Nixpkgs -> ParIO ()
generatePackageSet hackage nixpkgs = do
  let

    corePackageSet :: PackageSet
    corePackageSet = Map.fromList [ (name, v) | PackageIdentifier (PackageName name) v <- corePackages ++ hardCorePackages ]

    latestVersionSet :: PackageSet
    latestVersionSet = Map.map (Set.findMax . Map.keysSet) hackage

    defaultPackageOverridesSet :: PackageSet
    defaultPackageOverridesSet = Map.fromList [ (name, resolveConstraint c hackage) | c@(Dependency (PackageName name) _) <- defaultPackageOverrides ]

    generatedDefaultPackageSet :: PackageSet
    generatedDefaultPackageSet = (defaultPackageOverridesSet `Map.union` latestVersionSet) `Map.difference` corePackageSet

    latestCorePackageSet :: PackageSet
    latestCorePackageSet = latestVersionSet `Map.intersection` corePackageSet

    latestOverridePackageSet :: PackageSet
    latestOverridePackageSet = latestVersionSet `Map.intersection` defaultPackageOverridesSet

    extraPackageSet :: PackageMultiSet
    extraPackageSet = Map.unionsWith Set.union $
                        [ Map.singleton name (Set.singleton (resolveConstraint c hackage)) | c@(Dependency (PackageName name) _) <- extraPackages ] ++
                        [ Map.map Set.singleton latestCorePackageSet ] ++
                        [ Map.map Set.singleton latestOverridePackageSet ]

    defaultPkgs :: Hackage
    defaultPkgs = Map.mapWithKey (\k v -> Map.singleton v (hackage ! k Map.! v)) generatedDefaultPackageSet

    extraPkgs :: Hackage
    extraPkgs = Map.mapWithKey (\k -> Set.foldr (\v -> Map.insert v (hackage ! k Map.! v)) Map.empty) extraPackageSet

    db :: Hackage
    db = Map.unionWith Map.union defaultPkgs extraPkgs

  {-
    defaultPackageSet = buildDefaultPackageSet hackage defaultPackageOverrides
    extendedPackageSet = buildExtendedPackageSet hackage extraPackages
    db = defaultPackageSet `mergePackageSet` extendedPackageSet
   -}
    matches :: PackageIdentifier -> Dependency -> Bool
    matches (PackageIdentifier pn v) (Dependency dn vr) = pn == dn && v `withinRange` vr

    resolver :: Dependency -> Bool
    resolver dep@(Dependency (PackageName pkg) vrange) =
      any (`matches` dep) (corePackages ++ hardCorePackages) ||
      maybe False (not . Map.null . Map.filterWithKey (\k _ -> k `withinRange` vrange)) (Map.lookup pkg defaultPkgs)

  forM_ (Map.assocs defaultPkgs) $ \(name, vdb) ->
    when (Map.size vdb /= 1) $
      fail ("invalid defaut package set: " ++ show (name, Map.keys vdb))

  liftIO $ do putStrLn "/* hackage-packages.nix is an auto-generated file -- DO NOT EDIT! */"
              putStrLn ""
              putStrLn "{ pkgs, stdenv, callPackage }:"
              putStrLn ""
              putStrLn "self: {"
              putStrLn ""
  pkgs <- flip parMapM (Map.toList db) $ \(name, versions) -> do
    pkg <- forM (Map.toList versions) $ \(version, descr) -> do
      let isDefaultVersion :: Bool
          isDefaultVersion
            | Just _ <- Map.lookup name corePackageSet             = False
            | Just v <- Map.lookup name generatedDefaultPackageSet = v == version
            | otherwise                                            = False

      (drv, overrides) <- generatePackage db resolver nixpkgs name version descr

      let nixAttr = name ++ if isDefaultVersion then "" else "_" ++ [ if c == '.' then '_' else c | c <- display version ]

      let def = nest 2 $ hang (string nixAttr <+> equals <+> text "callPackage") 2 (parens (disp drv)) <+> (braces overrides <> semi)
      -- let overr = if not isDefaultVersion && isJust (Map.lookup name corePackageSet)
      --             then nest 2 $ (string name <+> equals <+> text "null") <> semi
      --             else empty

      return (def {- $+$ overr -})

    return (render (vcat pkg $+$ text ""))

  liftIO $ mapM_ putStrLn pkgs
  liftIO $ putStrLn "}"

generatePackage :: Hackage -> (Dependency -> Bool) -> Nixpkgs -> String -> Version -> GenericPackageDescription -> ParIO (Derivation, Doc)
generatePackage hackage resolver nixpkgs  name version descr = do
  srcSpec <- liftIO $ sourceFromHackage Nothing (name ++ "-" ++ display version)
  let Just cabalFileHash = lookup "x-cabal-file-hash" (customFieldsPD (packageDescription descr))

  -- TODO: Include list of broken dependencies in the generated output.
  -- Currently, we add overrides that set "pkgname = null", but this is
  -- unsatisfactory because these dependencies may very well work when building
  -- the same package set with a different GHC version.
      (_, _, drv') = cabal2nix resolver descr

  let drv = drv' { src = srcSpec
                 , editedCabalFile = if revision drv == 0 then "" else cabalFileHash
                 }

      selectHackageNames :: Set String -> Set String
      selectHackageNames = Set.intersection (Map.keysSet hackage `Set.union` Set.fromList [ n | PackageIdentifier (PackageName n) _ <- corePackages ++ hardCorePackages ])

      selectMissingHackageNames  :: Set String -> Set String
      selectMissingHackageNames = flip Set.difference (Map.keysSet hackage `Set.union` Set.fromList [ n | PackageIdentifier (PackageName n) _ <- corePackages ++ hardCorePackages ])

      conflicts :: Set String
      conflicts = Set.difference (selectHackageNames $ Set.fromList (extraLibs drv ++ pkgConfDeps drv)) missing

      conflictOverrides :: Doc
      conflictOverrides | Set.null conflicts = empty
                        | otherwise          = text " inherit (pkgs) " <> hsep (map text (Set.toAscList conflicts)) <> text "; "

      missing :: Set String
      missing = Set.unions
                [ Set.fromList (filter (not . isKnownNixpkgAttribute nixpkgs hackage) (extraLibs drv ++ pkgConfDeps drv ++ buildTools drv))
                , selectMissingHackageNames (Set.fromList (buildDepends drv ++ testDepends drv))
             -- , Set.fromList [ n | Dependency (PackageName n) _ <- missingDeps, n /= name ]
                ]

      missingOverrides :: Doc
      missingOverrides | Set.null missing = empty
                       | otherwise        = fcat [ text (' ':dep++" = null;") | dep <- Set.toAscList missing ] <> space

      overrides :: Doc
      overrides = conflictOverrides $+$ missingOverrides

  return (drv, overrides)

isKnownNixpkgAttribute :: Nixpkgs -> Hackage -> String -> Bool
isKnownNixpkgAttribute nixpkgs hackage name
  | '.' `elem` name                     = True
  | Just _ <- Map.lookup name hackage   = True
  | otherwise                           = maybe False goodScope (Map.lookup name nixpkgs)
  where
    goodScope :: Set [String] -> Bool
    goodScope = not . Set.null . Set.intersection (Set.fromList [[], ["xlibs"], ["gnome"]])

buildDefaultPackageSet :: Hackage -> [Dependency] -> Hackage
buildDefaultPackageSet hackage overrides = Map.unions $   -- unions is left-biased, i.e. overrides trump the latest version
  [ selectLatestMatchingPackage p hackage | p <- overrides ] ++
  [ selectLatestMatchingPackage (Dependency (PackageName n) anyVersion) hackage | n <- Map.keys hackage ]

buildExtendedPackageSet :: Hackage -> [Dependency] -> Hackage
buildExtendedPackageSet hackage extras = Map.unionsWith Map.union
  [ selectLatestMatchingPackage p hackage | p <- extras ]

mergePackageSet :: Hackage -> Hackage -> Hackage
mergePackageSet = Map.unionWith Map.union

-- These packages replace the latest respective version during dependency resolution.
defaultPackageOverrides :: [Dependency]
defaultPackageOverrides = map (\s -> fromMaybe (error (show s ++ " is not a valid override selector")) (simpleParse s))
  [ "mtl == 2.1.*"
  , "monad-control == 0.3.*"
  ] {- ++
  [ Dependency n (thisVersion v) | PackageIdentifier n v <- corePackages ]
     -- TODO: This is necessary because otherwise we may end up having a
     -- version that's "too new" in the default package set. The problem
     -- is that we don't want those packages generated, really, so maybe
     -- we should remove them from the final package set after the
     -- resover has been constructed?
  -}

-- These packages are added to the generated set, but the play no role during dependency resolution.
extraPackages :: [Dependency]
extraPackages =
  -- map (\(Dependency name _) -> Dependency name anyVersion) defaultPackageOverrides ++
  map (\s -> fromMaybe (error (show s ++ " is not a valid extra package selector")) (simpleParse s))
  [ "Cabal < 1.22"
  ]

selectLatestMatchingPackage :: Dependency -> Hackage -> Hackage
selectLatestMatchingPackage (Dependency (PackageName name) vrange) db = Map.singleton name (Map.singleton key val)
  where
    vdb = db ! name
    (key,val) = Map.findMax (Map.filterWithKey (\k _ -> k `withinRange` vrange) vdb)

-- data Options = Options
--   { verbose :: Bool
--   , compiler :: CompilerId
--   }
--   deriving (Show)
--
-- data Config = Config
--   { _verbose :: Bool
--   , _hackage :: Hackage
--   , _nixpkgs :: Nixpkgs
--   }
--   deriving (Show)
--
-- type Compile a = RWST Config () (Set PackageId) ParIO a
--
-- run :: Compile a -> IO a
-- run f = do
--   (a, st, ws) <- runParIO (runRWST f (Config True Map.empty Map.empty) Set.empty)
--   return a
--
-- parseCommandLine :: IO Options
-- parseCommandLine = execParser mainOptions
--   where
--     parseCompilerId :: Parser CompilerId
--     parseCompilerId = option (eitherReader (\s -> maybe (Left (show s ++ " is no valid compiler id")) Right (simpleParse s)))
--                       (  long "compiler"
--                       <> help "identifier of the compiler"
--                       <> metavar "COMPILER-ID"
--                       <> value (fromJust (simpleParse "ghc-7.8.3"))
--                       <> showDefaultWith display
--                       )
--
--     parseOptions :: Parser Options
--     parseOptions = Options
--       <$> switch (long "verbose" <> help "enable detailed progress diagnostics")
--       <*> parseCompilerId
--
--     mainOptions :: ParserInfo Options
--     mainOptions = info (helper <*> parseOptions)
--       (  fullDesc
--          <> header "hackage2nix -- convert the Hackage database into Nix build instructions"
--       )

cabal2nix :: (Dependency -> Bool) -> GenericPackageDescription -> ([Dependency], FlagAssignment, Derivation)
cabal2nix resolver cabal = (missingDeps, flags, drv)
  where
    drv = (cabal2nix' descr) { configureFlags = [ "-f" ++ (if b then "" else "-") ++ n | (FlagName n, b) <- flags ] }

    Right (descr, flags) = finalize (if null missingDeps then resolver else const True) cabal

    missingDeps :: [Dependency]
    missingDeps = either id (const [])  (finalize resolver cabal')

    finalize :: (Dependency -> Bool) -> GenericPackageDescription -> Either [Dependency] (PackageDescription, FlagAssignment)
    finalize resolver' = finalizePackageDescription
                           (configureCabalFlags (package (packageDescription cabal)))
                           resolver'
                           (Platform X86_64 Linux)                 -- shouldn't be hardcoded
                           (CompilerId GHC (Version [7,8,4] []))   -- ditto
                           []                                      -- no additional constraints

    -- A variant of the cabal file that has all test suites enabled to ensure
    -- that their dependencies are recognized by finalizePackageDescription.
    cabal' :: GenericPackageDescription
    cabal' = cabal { condTestSuites = flaggedTests }

    flaggedTests :: [(String, CondTree ConfVar [Dependency] TestSuite)]
    flaggedTests = map (\(n, t) -> (n, mapTreeData enableTest t)) (condTestSuites cabal)

    enableTest :: TestSuite -> TestSuite
    enableTest t = t { testEnabled = True }

corePackages :: [PackageIdentifier]             -- Core packages found on Hackageg
corePackages = map (\s -> fromMaybe (error (show s ++ " is not a valid core package")) (simpleParse s))
  [ "Cabal-1.18.1.5"
  , "array-0.5.0.0"
  , "base-4.7.0.2"
  , "binary-0.7.1.0"
  , "bytestring-0.10.4.0"
  , "containers-0.5.5.1"
  , "deepseq-1.3.0.2"
  , "directory-1.2.1.0"
  , "filepath-1.3.0.2"
  , "ghc-prim-0.3.1.0"
  , "haskeline-0.7.1.2"
  , "haskell2010-1.1.2.0"
  , "haskell98-2.0.0.3"
  , "hoopl-3.10.0.1"
  , "hpc-0.6.0.1"
  , "integer-gmp-0.5.1.0"
  , "old-locale-1.0.0.6"
  , "old-time-1.1.0.2"
  , "pretty-1.1.1.1"
  , "process-1.2.0.0"
  , "template-haskell-2.9.0.0"
  , "terminfo-0.4.0.0"
  , "time-1.4.2"
  , "transformers-0.3.0.0"
  , "unix-2.7.0.1"
  , "xhtml-3000.2.1"
  ]

hardCorePackages :: [PackageIdentifier]         -- Core packages not found on Hackage.
hardCorePackages = map (\s -> fromMaybe (error (show s ++ " is not a valid core package")) (simpleParse s))
  [ "bin-package-db-0.0.0.0"
  , "ghc-7.8.4"
  , "rts-1.0"
  ]