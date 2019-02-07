module Pie.Parse where

import Control.Applicative
import Data.Char
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.ICU as ICU

import Pie.Types

data ParseErr = GenericParseErr
              | ExpectedChar Char
              | Expected Text
              | EOF
  deriving Show


data ParserContext =
  ParserContext
    { currentFile :: FilePath
    }

data ParserState =
  ParserState
    { currentInput :: Text
    , currentPos :: Pos
    }

newtype Parser a =
  Parser
    { runParser ::
        ParserContext ->
        ParserState ->
        Either (Positioned ParseErr) (a, ParserState)
    }

instance Functor Parser where
  fmap f (Parser fun) =
    Parser (\ ctx st ->
              case fun ctx st of
                Left err -> Left err
                Right (x, st') -> Right (f x, st'))

instance Applicative Parser where
  pure x = Parser (\_ st -> Right (x, st))
  Parser fun <*> Parser arg =
    Parser (\ ctx st ->
              case fun ctx st of
                Left err -> Left err
                Right (f, st') ->
                  case arg ctx st' of
                    Left err -> Left err
                    Right (x, st'') ->
                      Right (f x, st''))

instance Alternative Parser where
  empty = Parser (\ctx st -> Left (Positioned (currentPos st) GenericParseErr))
  Parser p1 <|> Parser p2 =
    Parser (\ctx st ->
              case p1 ctx st of
                Left _ -> p2 ctx st
                Right ans -> Right ans)

instance Monad Parser where
  return = pure
  Parser act >>= f =
    Parser (\ ctx st ->
              case act ctx st of
                Left err -> Left err
                Right (x, st') ->
                  runParser (f x) ctx st')

eof :: Parser ()
eof = Parser (\ _ st ->
                if T.null (currentInput st)
                  then Right ((), st)
                  else Left (Positioned (currentPos st) (Expected (T.pack "EOF"))))

failure :: ParseErr -> Parser a
failure e = Parser (\ _ st -> Left (Positioned (currentPos st) e))

get :: Parser ParserState
get = Parser (\ctx st -> Right (st, st))

modify :: (ParserState -> ParserState) -> Parser ()
modify f = Parser (\ctx st -> Right ((), f st))

put :: ParserState -> Parser ()
put = modify . const

getContext :: Parser ParserContext
getContext = Parser (\ctx st -> Right (ctx, st))


forwardLine :: Pos -> Pos
forwardLine (Pos line col) = Pos (line + 1) 1

forwardCol :: Pos -> Pos
forwardCol (Pos line col) = Pos line (col + 1)

forwardCols :: Int -> Pos -> Pos
forwardCols n (Pos line col) = Pos line (col + n)



char :: Parser Char
char =
  do st <- get
     case T.uncons (currentInput st) of
       Nothing -> failure EOF
       Just (c, more) ->
         do put st { currentInput = more
                   , currentPos =
                     if c == '\n'
                       then forwardLine (currentPos st)
                       else forwardCol (currentPos st)
                   }
            return c

litChar :: Char -> Parser ()
litChar c =
  do c' <- char
     if c == c' then pure () else failure (ExpectedChar c)

rep :: Parser a -> Parser [a]
rep p = ((:) <$> p <*> (rep p)) <|> pure []

rep1 :: Parser a -> Parser (NonEmpty a)
rep1 p = (:|) <$> p <*> rep p


located :: Parser a -> Parser (Located a)
located p =
  do file <- currentFile <$> getContext
     startPos <- currentPos <$> get
     res <- p
     endPos <- currentPos <$> get
     return (Located (Loc file startPos endPos) res)

string :: String -> Parser ()
string [] = pure ()
string (c:cs) =
  do c' <- char
     if c /= c'
       then failure (ExpectedChar c)
       else string cs

spanning :: (Char -> Bool) -> Parser Text
spanning p =
  do (matching, rest) <- T.span p . currentInput <$> get
     case T.lines matching of
       [] -> modify (\st -> st { currentInput = rest })
       ls -> modify (\st -> st { currentInput = rest
                               , currentPos = let Pos l c = currentPos st
                                              in Pos (l + length ls) (c + T.length (last ls))
                               })
     return matching

regex :: Text -> [Char] -> Parser Text
regex name rx =
  do input <- currentInput <$> get
     case (ICU.find theRegex input) >>= ICU.group 0  of
       Nothing -> failure (Expected name)
       Just matching ->
         do let rest = T.drop (T.length matching) input
            case T.lines matching of
              [] -> modify (\st -> st { currentInput = rest })
              [l] -> modify (\st -> st { currentInput = rest
                                       , currentPos = forwardCols (T.length l) (currentPos st)
                                       })
              ls -> modify (\st -> st { currentInput = rest
                                      , currentPos =
                                          let Pos l c = currentPos st
                                          in Pos (l + length ls - 1) (T.length (last ls))
                                      })
            return matching
  where
    theRegex = ICU.regex [] (T.pack ('^' : rx))

hashLang :: Parser ()
hashLang = regex (T.pack "language identification") "#lang pie" *> eatSpaces

ident :: Parser Text
ident = regex (T.pack "identifier") "[\\p{Letter}-][\\p{Letter}0-9₀₁₂₃₄₅₆₇₈₉-]*"

token :: Parser a -> Parser a
token p = p <* eatSpaces

varName =
  token $
  do x <- Symbol <$> ident
     if x `elem` pieKeywords
       then failure (Expected (T.pack "valid name"))
       else return x

kw k = token (string k)

eatSpaces :: Parser ()
eatSpaces = spanning isSpace *> pure ()

parens :: Parser a -> Parser a
parens p = token (litChar '(') *> p <* token (litChar ')')

pair x y = (x, y)

expr :: Parser Expr
expr = Expr <$> located expr'

expr' :: Parser (Expr' Expr)
expr' = u <|> nat <|> triv <|> sole <|> tick <|> atom <|> zero <|> natLit <|> (Var <$> varName) <|> compound
  where
    u = kw "U" *> pure U
    nat = kw "Nat" *> pure Nat
    atom = kw "Atom" *> pure Atom
    zero = kw "zero" *> pure Zero
    triv = kw "Trivial" *> pure Trivial
    sole = kw "sole" *> pure Sole
    tick = Tick . Symbol <$> (litChar '\'' *> ident) -- TODO separate atom name from var name - atom name has fewer possibilities!
    natLit = do i <- read . T.unpack <$>
                       token (regex (T.pack "natural number literal") "[0-9]+")
                makeNat i

    compound =
      parens (add1 <|> indNat <|> lambda <|> pi <|> arrow <|> the <|> sigma <|> pairT <|> cons <|> car <|> cdr <|> app)

    add1 = kw "add1" *> (Add1 <$> expr)

    lambda = kw "lambda" *> (Lambda <$> argList <*> expr)
      where argList = parens (rep1 varName)

    pi = kw "Pi" *> (Pi <$> parens (rep1 (parens (pair <$> varName <*> expr))) <*> expr)

    arrow = kw "->" *> (Arrow <$> expr <*> rep1 expr)

    sigma = kw "Sigma" *> (Sigma <$> parens (rep1 (parens (pair <$> varName <*> expr))) <*> expr)
    pairT = kw "Pair" *> (Pair <$> expr <*> expr)
    cons = kw "cons" *> (Cons <$> expr <*> expr)
    indNat = kw "ind-Nat" *> (IndNat <$> expr <*> expr <*> expr <*> expr)
    car = kw "car" *> (Car <$> expr)
    cdr = kw "cdr" *> (Cdr <$> expr)

    the = kw "the" *> (The <$> expr <*> expr)

    app = App <$> expr <*> expr <*> rep expr

    makeNat :: Integer -> Parser (Expr' Expr)
    makeNat i
      | i < 1 = return Zero
      | otherwise = Add1 . Expr <$> located (makeNat (i - 1))

testParser :: Parser a -> String -> Either (Positioned ParseErr) a
testParser (Parser p) input =
  let initSt = ParserState (T.pack input) (Pos 1 1)
      initCtx = ParserContext "<test input>"
  in case p initCtx initSt of
       Left err -> Left err
       Right (x, _) -> Right x
