#!/usr/bin/env /usr/local/bin/mscript
<!
        strict;
        name: irc-discord-bridge.ms;
        author: cailin;
        created: 2019-02-11;
        description: Bridges IRC and Discord, and provides some basic bot functionality.;
	requiredExtensions: Core, CHDiscord, CHIRC;
>

/**
 * Puts a non-printing space between each letter, so that this will look normal, but not ping the same user that just talked, if they
 * are in both IRC and discord, and have the same user name.
 */
proc _processNick(@nick) {
	string @newNick = '';
	foreach(@letter in @nick) {
		@newNick .= '\u200b' . @letter;
	}
	return(@newNick);
}

/**
 * Returns true if this is a command
 */
proc _isCommand(@line) {
	return(string_starts_with(@line, '~'));
}

/**
 * Assumes the line is a command, and handles it accordingly.
 */
proc _handleCommand(@line, @source) {
	@line = substr(@line, 1);
	array @commands = array(
		'ping': closure(){ return('pong'); },
		'api': closure(@args) {
			msg(typeof(@args) . ' ' . length(@args) . ' ' . @args);
			if(length(@args) == 1) {
				return("~api <function>");
			}
			string @f = @args[1];
			always_trace(@f);
			string @type = reflect_docs(@f, 'type');
			string @return = reflect_docs(@f, 'return');
			string @a = reflect_docs(@f, 'args');
			string @description = reflect_docs(@f, 'description');
			string @ret = "@type @f(@a);\n";
			if(length(@description) > 512) {
				@description = @description[0..512] . "...";
			}
			return(@ret . @description . '\nhttps://methodscript.com/docs/' . extension_info('Core')['version'] . '/API/functions/' . @f . '.html');
		}
	);
	array @args = parse_args(@line, true);
	if(array_index_exists(@commands, @args[0])) {
		string @ret = execute(@args, @source, @commands[@args[0]]);
		if(@ret != null) {
			_broadcastAll(@ret, 'general');
		}
	} else {
		_broadcastAll("Could not find command \"@{args[0]}\"", 'general');
	} 
}

proc _broadcastDiscord(@line, @channel) {
	discord_broadcast(@channel, @line);
}

proc _broadcastIRC(@line) {
	irc_msg(1, '#CommandHelper', @line);
}

proc _broadcastAll(@line, @discordChannel) {
	_broadcastDiscord(@line, @discordChannel);
	_broadcastIRC(@line);
}

execute(closure(){
  array @redirect = associative_array(
	'travis-ci': 'botspam',
	'SocBot': 'botspam',
  );
  discord_connect('discord', closure(){
    msg('Attempting connect to irc');
    irc_create(1);
    bind('irc_connection_exception', null, null, @event) {
      msg('Connection failure: ' . @event);
    }
    array @options = array(
      'username': 'MSBot',
      'realname': 'MSBot',
      'runsync': true
    );
    irc_connect(1, 'MSBot', 'irc.esper.net', @options);
    bind('irc_welcomed', null, null, @event) {
      irc_join(1, '#CommandHelper');
      msg('Connected to IRC');
    }

    bind('irc_msg', null, null, @event, @redirect) {
	msg('IRC: ' . @event);
	_broadcastDiscord("(IRC) " . @event['who'] . ": " . @event['message'],
		if(array_index_exists(@redirect, @event['who']), @redirect[@event['who']], 'general'));
	if(_isCommand(@event['message'])) {
		_handleCommand(@event['message'], 'irc');
	}
    }

    bind('discord_message_received', null, null, @event) {
      if(@event['channel'] == 'general') {
        string @nick = @event['nickname'];
        string @message = @event['message'];
	msg('Discord: ' . @event);
	_broadcastIRC("[D]"._processNick(@nick).": @message");
	if(_isCommand(@message)) {
		_handleCommand(@message, 'discord');
	}
      }
    }
  });
});