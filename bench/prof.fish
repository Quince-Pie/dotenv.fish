source ../functions/dotenv.fish
for i in (string split ' ' (string repeat -n 30 'x ')); dotenv $argv[1]; end
