# Arbitrum airdrop scripts

*All responsibility for running scripts lies entirely on your shoulders*
*No warranties*


#### TG [channel](https://t.me/arbitrum_airdrop_ruby_script) and [chat](https://t.me/arbitrum_airdrop_rb_script_chat) (rare answers, sorry, public)


## Features
- Random changable proxy (also can work without proxy) (see `proxy_list:`)
- Random changable rpc (if bad response received from RPC - it will be randomly changed to unused) (see `rpcs_list:`)
- Multithreading (threads count can be set by settings) (see `threads_count:`)
- Gas limit adaptation strategy (through request, or will be used from settings) __Be aware, if set by settings will not be changeable (restart script)__
- Gas price adaptation strategy (initial can be set in settings)
- You can stop/start program in any time. It will not affect anything
- If something went wrong - you start script again. But see output, maybe some actions needed

## Scripts set
- [Claimer](#claimer) (for claim tokens)
- [Transferer](#transferer) (for transfer tokens)
- [Seeder](#seeder) (for seeding native coins)
- [1inchDrainer](#1inchdrainer) (for drain tokens in 1inch aggregation protocol v5)


### Main notes
- Script can be launched at any time
- If script dropped - analyze log - and run it again
- If you want to stop script execution - use `CTRL+C` hotkey
- Proxy takes randomly - every request - random proxy
- Use `production:` settings section for run

### Requirements:
- ruby 3.1.3

### Environment installation guide
#### For Windows
- Install [Sublime Merge](https://www.sublimemerge.com/)
- Install [RubyInstaller (3.1.3)](https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-3.1.3-1/rubyinstaller-devkit-3.1.3-1-x64.exe) (dowloads [page](https://rubyinstaller.org/downloads/))
- Clone this repository `https://github.com/d4mk0/ArbitrumAirdrop.git` by Sublime Merge
- Open folder with this project and open PowerShell window inside folder
- Run `bundle`

#### For Mac/Linux
- Open terminal and run inside
- Install brew
```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval $(/opt/homebrew/bin/brew shellenv)' >> $HOME/.zshrc
eval $(/opt/homebrew/bin/brew shellenv)
```
- Install git through brew
```sh
brew install git
```
- Clone repository
```sh
git clone https://github.com/d4mk0/ArbitrumAirdrop.git
```
- Go to folder
```sh
cd ArbitrumAirdrop
```
- Install rvm
```sh
gpg --keyserver keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
curl -sSL https://get.rvm.io | bash
source $HOME/.rvm/scripts/rvm
echo 'source ~/.rvm/scripts/rvm' >> $HOME/.zsh_profile
```
- Install ruby `rvm install 3.1.3`
- Run `bundle`



### Claimer
_Use to claim tokens_

#### Logic:
- Script checks current wallets situation and displays it on screen.
- When we have < 3 blocks (~30 seconds) before claim - displaying stopped and current block info only showed
- When we reach start block - script will try execute claim function if wallet have correct amount of eth

#### Run command
```sh
ruby claimer.rb
```

#### Required:
- fill `claimer/wallets.txt` by private keys (one per line)
- check `claimer/claimer_settings.yml` ensure its correct
    - `l1_block_start_period` claim will be started at 16890400 block (Ethereum mainnet)
    - `eth_border` - to ensure what u wallets have amount of ETH for claim/transfer fee

### Transferer

_Use to transfer tokens_

#### Logic:
- Script checks current wallets token and eth balances and displays it on screen.
- When some tokens available on wallet and eth for fee - present. It will try make transfer tokens to presented wallet

#### Notes:
- You can add two lines for transferring like this (wallet1(minter) -> wallet2(proxy) -> wallet3(exchange))

#### Required:
- fill `transferer/wallets.txt` by list of private_key and address to transfer (one private key per line, one address for send per line)
- check `transferer/transferer_settings.yml` ensure its correct
    - `eth_border` - to ensure what u wallets have amount of ETH for claim/transfer fee

#### Run command
```sh
ruby transferer.rb
```

### Seeder

_Use to transfer native ETH coins to wallets when specified L1 block will be created_

#### Notes:
- If you set one private key multiple times - it can cause bad nonce error (its ok, it will be retryable, but sending can take longer time). Best - use 1 private key one time.

#### Required:
- fill `seeder/wallets.txt` by private_keys for seeder and addresses to transfer
- check `seeder/seeder_settings.yml` ensure its correct
    - `amount_to_send` eth amount to sending in WEI
    - `l1_block_start_period` claim will be started at 16890400 block (Ethereum mainnet)

#### Run command
```sh
ruby seeder.rb
```

### 1inchDrainer

_Use to fast swap tokens_

#### Notes:
- Script will do swap until it have correct conditions (it can stop only if amount to swap higher than wallet balance)
- Sorry only can works with 1 account. If u need 2+ - clone script into another path and run it together.
- Script will give approve for 1inch spender contract automatically.
- You can start script in any time, and stop it ofk. It will make swap when swap conditions will be true (also correct balance).

#### Required:
- check `one_inch_drainer/one_inch_drainer_settings.yml` ensure its correct
    - `private_key` private key
    - `approve_address` - 1inch spender can take it from `https://api.1inch.io/v5.0/42161/approve/spender`
    - `swap_if_price_higher` - if price will higher than entered - swap will be executed, or no if not
    - `amount_to_swap` - amount for swap (ensure correct)
    - `slippage` - percent of slippage (if token new - higher, maybe better, max 50)
    - `swap_to_token` - address of token to swap (i.e. USDT)
    - `eth_border` - to ensure what u wallets have amount of ETH for swap fee

#### Run command
```sh
ruby one_inch_drainer.rb
```

##### Run for test (i.e. swap DAI -> USDT, ensure DAI balance)
```sh
ruby one_inch_drainer.rb test
```

###### Donations. If u satisfy u can send some tips to 0xAB3966f0BDCB6D67a35C99F383C23c7350FB8943
