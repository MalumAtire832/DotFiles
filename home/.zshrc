# Lines configured by zsh-newuser-install
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000
bindkey -e
# End of lines configured by zsh-newuser-install
# The following lines were added by compinstall
zstyle :compinstall filename '/home/malum/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall

source ~/.zsh/headline.zsh-theme
export PATH="$HOME/.local/bin:$PATH"

export XDG_CURRENT_DESKTOP=sway

eval "$(rbenv init - zsh)"

# ---------------------------------------------------------------------------
# Key bindings (Home / End / Delete / word-skip / etc.)
#
# Driven by terminfo where possible, so this keeps working if the terminal
# emulator is ever swapped out. Literal sequences are listed as fallbacks for
# the cases terminfo does not describe (modified arrows, ctrl+backspace).
# ---------------------------------------------------------------------------

# Put the terminal into "application mode" for the duration of each prompt.
# Without this, terminfo's khome/kend describe sequences the terminal only
# emits in application mode, so Home/End work in other programs but not in zsh.
if (( ${+terminfo[smkx]} )) && (( ${+terminfo[rmkx]} )); then
    autoload -Uz add-zle-hook-widget

    function _keybind-application-mode-on {
        echoti smkx
    }
    function _keybind-application-mode-off {
        echoti rmkx
    }

    zle -N _keybind-application-mode-on
    zle -N _keybind-application-mode-off
    add-zle-hook-widget line-init _keybind-application-mode-on
    add-zle-hook-widget line-finish _keybind-application-mode-off
fi

# Bind a terminfo capability only if the terminal actually reports it.
function _bindkey-terminfo {
    local cap=$1 widget=$2
    if (( ${+terminfo[$cap]} )); then
        bindkey -- "${terminfo[$cap]}" "$widget"
    fi
}

# Navigation
_bindkey-terminfo khome beginning-of-line
_bindkey-terminfo kend  end-of-line
_bindkey-terminfo kcuu1 up-line-or-history
_bindkey-terminfo kcud1 down-line-or-history
_bindkey-terminfo kpp   up-line-or-history      # Page Up
_bindkey-terminfo knp   down-line-or-history    # Page Down

# Editing
_bindkey-terminfo kdch1 delete-char             # Delete
_bindkey-terminfo kbs   backward-delete-char    # Backspace
_bindkey-terminfo kich1 overwrite-mode          # Insert
_bindkey-terminfo kcbt  reverse-menu-complete   # Shift+Tab

unfunction _bindkey-terminfo

# Both the normal (CSI) and application (SS3) forms of Home/End, since which
# one arrives depends on the terminal's current mode.
bindkey -- '^[[H'  beginning-of-line
bindkey -- '^[OH'  beginning-of-line
bindkey -- '^[[1~' beginning-of-line
bindkey -- '^[[F'  end-of-line
bindkey -- '^[OF'  end-of-line
bindkey -- '^[[4~' end-of-line
bindkey -- '^[[3~' delete-char

# Word-skip: Ctrl+Left / Ctrl+Right, with the xterm, rxvt and legacy variants.
bindkey -- '^[[1;5D' backward-word
bindkey -- '^[[1;5C' forward-word
bindkey -- '^[[5D'   backward-word
bindkey -- '^[[5C'   forward-word
bindkey -- '^[Od'    backward-word
bindkey -- '^[Oc'    forward-word

# Word-skip: Alt+Left / Alt+Right (and Alt+B / Alt+F, which emacs mode already
# provides, listed here so the whole set lives in one place).
bindkey -- '^[[1;3D' backward-word
bindkey -- '^[[1;3C' forward-word
bindkey -- '^[b'     backward-word
bindkey -- '^[f'     forward-word

# Word-delete: Ctrl+Backspace and Ctrl+Delete.
# Terminals disagree about what Ctrl+Backspace sends, so bind all three.
bindkey -- '^H'      backward-kill-word
bindkey -- '^[^?'    backward-kill-word
bindkey -- '^[[3;5~' kill-word

# Ctrl+Home / Ctrl+End: jump to the start or end of the whole buffer.
bindkey -- '^[[1;5H' beginning-of-buffer-or-history
bindkey -- '^[[1;5F' end-of-buffer-or-history
