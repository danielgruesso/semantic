{-# LANGUAGE DataKinds, TypeOperators, ScopedTypeVariables #-}
module Command.Parse where

import Arguments
import Category
import Data.Aeson (ToJSON, toJSON, encode, object, (.=))
import Data.Functor.Foldable hiding (Nil)
import Data.Record
import qualified Data.Text as T
import Git.Blob
import Git.Libgit2
import Git.Repository
import Git.Types
import qualified Git
import Info
import Language
import Language.Markdown
import Parser
import Prologue
import Source
import Syntax
import System.FilePath
import Term
import TreeSitter
import Renderer.JSON()
import Renderer.SExpression
import Text.Parser.TreeSitter.C
import Text.Parser.TreeSitter.Go
import Text.Parser.TreeSitter.JavaScript
import Text.Parser.TreeSitter.Ruby
import Text.Parser.TreeSitter.TypeScript

data ParseTreeFile = ParseTreeFile { parseTreeFilePath :: FilePath, node :: ParseNode } deriving (Show)

instance ToJSON ParseTreeFile where
  toJSON ParseTreeFile{..} = object [ "filePath" .= parseTreeFilePath, "programNode" .= node ]


data IndexFile = IndexFile { indexFilePath :: FilePath, nodes :: [ParseNode] } deriving (Show)

instance ToJSON IndexFile where
  toJSON IndexFile{..} = object [ "filePath" .= indexFilePath, "programNodes" .= nodes ]


data ParseNode = ParseNode
  { category :: Text
  , sourceRange :: Range
  , sourceText :: Maybe SourceText
  , sourceSpan :: SourceSpan
  , identifier :: Maybe Text
  , children :: Maybe [ParseNode]
  }
  deriving (Show)

instance ToJSON ParseNode where
  toJSON ParseNode{..} =
    object
    $  [ "category" .= category, "sourceRange" .= sourceRange, "sourceSpan" .= sourceSpan ]
    <> [ "sourceText" .= sourceText | isJust sourceText ]
    <> [ "identifier" .= identifier | isJust identifier ]
    <> [ "children"   .= children   | isJust children   ]

-- | Parses file contents into an SExpression format for the provided arguments.
parseSExpression :: Arguments -> IO ByteString
parseSExpression =
  pure . printTerms TreeOnly <=< parse <=< sourceBlobsFromArgs
  where parse = traverse (\sourceBlob@SourceBlob{..} -> parserForType (toS (takeExtension path)) sourceBlob)

type RAlgebra t a = Base t (t, a) -> a

parseRoot :: (FilePath -> nodes -> root) -> (RAlgebra (Term (Syntax Text) (Record '[Maybe SourceText, Range, Category, SourceSpan])) nodes) -> Arguments -> IO [root]
parseRoot construct algebra args@Arguments{..} = do
  blobs <- sourceBlobsFromArgs args
  for blobs (buildParseNodes construct algebra (parseDecorator debug))

-- | Constructs IndexFile nodes for the provided arguments and encodes them to JSON.
parseIndex :: Arguments -> IO ByteString
parseIndex = fmap (toS . encode) . parseRoot IndexFile algebra
  where
    algebra :: RAlgebra (Term (Syntax Text) (Record '[Maybe SourceText, Range, Category, SourceSpan])) [ParseNode]
    algebra (annotation :< syntax) = ParseNode (toS (Info.category annotation)) (byteRange annotation) (rhead annotation) (Info.sourceSpan annotation) (identifierFor (Prologue.fst <$> syntax)) Nothing : (Prologue.snd =<< toList syntax)

-- | Constructs ParseTreeFile nodes for the provided arguments and encodes them to JSON.
parseTree :: Arguments -> IO ByteString
parseTree = fmap (toS . encode) . parseRoot ParseTreeFile algebra
  where
    algebra :: RAlgebra (Term (Syntax Text) (Record '[Maybe SourceText, Range, Category, SourceSpan])) ParseNode
    algebra (annotation :< syntax) = ParseNode (toS (Info.category annotation)) (byteRange annotation) (rhead annotation) (Info.sourceSpan annotation) (identifierFor (Prologue.fst <$> syntax)) (Just (Prologue.snd <$> toList syntax))

-- | Determines the term decorator to use when parsing.
parseDecorator :: (Functor f, HasField fields Range) => Bool -> (Source -> TermDecorator f fields (Maybe SourceText))
parseDecorator True = termSourceTextDecorator
parseDecorator False = const . const Nothing

-- | Function context for constructing parse nodes given a parse node constructor, an algebra (for a paramorphism), a function that takes a file's source and returns a term decorator, and a list of source blobs.
-- This function is general over b such that b represents IndexFile or ParseTreeFile.
buildParseNodes
  :: forall nodes b. (FilePath -> nodes -> b)
  -> (RAlgebra (Cofree (Syntax Text) (Record '[Maybe SourceText, Range, Category, SourceSpan])) nodes)
  -> (Source -> TermDecorator (Syntax Text) DefaultFields (Maybe SourceText))
  -> SourceBlob
  -> IO b
buildParseNodes programNodeConstructor algebra termDecorator sourceBlob@SourceBlob{..} = do
  parsedTerm <- parseWithDecorator (termDecorator source) path sourceBlob
  let parseNode = para algebra parsedTerm
  pure $ programNodeConstructor path parseNode

-- | For the given absolute file paths, retrieves their source blobs.
sourceBlobsFromPaths :: [FilePath] -> IO [SourceBlob]
sourceBlobsFromPaths filePaths =
  for filePaths (\filePath -> do
                  source <- readAndTranscodeFile filePath
                  pure $ Source.SourceBlob source mempty filePath (Just Source.defaultPlainBlob))

-- | For the given sha, git repo path, and file paths, retrieves the source blobs.
sourceBlobsFromSha :: [Char] -> [Char] -> [FilePath] -> IO [SourceBlob]
sourceBlobsFromSha commitSha gitDir filePaths = do
  maybeBlobs <- withRepository lgFactory gitDir $ do
    repo   <- getRepository
    object <- parseObjOid (toS commitSha)
    commit <- lookupCommit object
    tree   <- lookupTree (commitTree commit)
    lift $ runReaderT (traverse (toSourceBlob tree) filePaths) repo

  pure $ catMaybes maybeBlobs

  where
    toSourceBlob :: Git.Tree LgRepo -> FilePath -> ReaderT LgRepo IO (Maybe SourceBlob)
    toSourceBlob tree filePath = do
      entry <- treeEntry tree (toS filePath)
      case entry of
        Just (BlobEntry entryOid entryKind) -> do
          blob <- lookupBlob entryOid
          bytestring <- blobToByteString blob
          let oid = renderObjOid $ blobOid blob
          s <- liftIO $ transcode bytestring
          pure . Just $ SourceBlob s (toS oid) filePath (Just (toSourceKind entryKind))
        _ -> pure Nothing
      where
        toSourceKind :: Git.BlobKind -> SourceKind
        toSourceKind (Git.PlainBlob mode) = Source.PlainBlob mode
        toSourceKind (Git.ExecutableBlob mode) = Source.ExecutableBlob mode
        toSourceKind (Git.SymlinkBlob mode) = Source.SymlinkBlob mode

-- | Returns a Just identifier text if the given Syntax term contains an identifier (leaf) syntax. Otherwise returns Nothing.
identifierFor :: StringConv leaf T.Text => Syntax leaf (Term (Syntax leaf) (Record '[(Maybe SourceText), Range, Category, SourceSpan])) -> Maybe T.Text
identifierFor = fmap toS . extractLeafValue . unwrap <=< maybeIdentifier

-- | For the file paths and commit sha provided, extract only the BlobEntries and represent them as SourceBlobs.
sourceBlobsFromArgs :: Arguments -> IO [SourceBlob]
sourceBlobsFromArgs Arguments{..} =
  case commitSha of
    Just commitSha' -> sourceBlobsFromSha commitSha' gitDir filePaths
    _ -> sourceBlobsFromPaths filePaths

-- | Return a parser incorporating the provided TermDecorator.
parseWithDecorator :: TermDecorator (Syntax Text) DefaultFields field -> FilePath -> Parser (Syntax Text) (Record '[field, Range, Category, SourceSpan])
parseWithDecorator decorator path blob = decorateTerm decorator <$> parserForType (toS (takeExtension path)) blob

-- | Return a parser based on the file extension (including the ".").
parserForType :: Text -> Parser (Syntax Text) (Record DefaultFields)
parserForType mediaType = maybe lineByLineParser parserForLanguage (languageForType mediaType)

-- | Select a parser for a given Language.
parserForLanguage :: Language -> Parser (Syntax Text) (Record DefaultFields)
parserForLanguage language = case language of
  C -> treeSitterParser C tree_sitter_c
  JavaScript -> treeSitterParser JavaScript tree_sitter_javascript
  TypeScript -> treeSitterParser TypeScript tree_sitter_typescript
  Markdown -> cmarkParser
  Ruby -> treeSitterParser Ruby tree_sitter_ruby
  Language.Go -> treeSitterParser Language.Go tree_sitter_go

-- | Decorate a 'Term' using a function to compute the annotation values at every node.
decorateTerm :: (Functor f) => TermDecorator f fields field -> Term f (Record fields) -> Term f (Record (field ': fields))
decorateTerm decorator = cata $ \ term -> cofree ((decorator (extract <$> term) :. headF term) :< tailF term)

-- | A function computing a value to decorate terms with. This can be used to cache synthesized attributes on terms.
type TermDecorator f fields field = TermF f (Record fields) (Record (field ': fields)) -> field

-- | Term decorator extracting the source text for a term.
termSourceTextDecorator :: (Functor f, HasField fields Range) => Source -> TermDecorator f fields (Maybe SourceText)
termSourceTextDecorator source term = Just . SourceText . toText $ Source.slice range' source
 where range' = byteRange $ headF term

-- | A fallback parser that treats a file simply as rows of strings.
lineByLineParser :: Parser (Syntax Text) (Record DefaultFields)
lineByLineParser SourceBlob{..} = pure . cofree . root $ case foldl' annotateLeaves ([], 0) lines of
  (leaves, _) -> cofree <$> leaves
  where
    lines = actualLines source
    root children = (sourceRange :. Program :. rangeToSourceSpan source sourceRange :. Nil) :< Indexed children
    sourceRange = Source.totalRange source
    leaf charIndex line = (Range charIndex (charIndex + T.length line) :. Program :. rangeToSourceSpan source (Range charIndex (charIndex + T.length line)) :. Nil) :< Leaf line
    annotateLeaves (accum, charIndex) line =
      (accum <> [ leaf charIndex (Source.toText line) ] , charIndex + Source.length line)

-- | Return the parser that should be used for a given path.
parserForFilepath :: FilePath -> Parser (Syntax Text) (Record DefaultFields)
parserForFilepath = parserForType . toS . takeExtension
