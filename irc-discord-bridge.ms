#!/usr/bin/env /usr/local/bin/mscript
<!
        strict;
        name: irc-discord-bridge.ms;
        author: cailin;
        created: 2019-02-11;
        description: Bridges IRC and Discord, and provides some basic bot functionality.;
	requiredExtensions: Core, CHDiscord, CHIRC;
>

proc _getAPIObject() {
	@lastUpdated = import('api_last_updated', 0);
	if(@lastUpdated + (1000 * 60 * 10) < time()) {
		msg('API is stale, updating');
		http_request('https://methodscript.com/docs/' . extension_info('Core')['version'] . '/api.json', array(
			blocking: true,
			success: closure(@data) {
				@data = json_decode(@data['body']);
				export('api_data', @data);
				export('api_last_updated', time());
				msg('API Updated in memory');
			}
		));
	}
	return(import('api_data'));
}

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
 * If @discordChannel is null, then it is assumed to be from the general/IRC channel, and is handled appropriately, otherwise,
 * if not null, the response will only go to the given discord channel. If both source and discordChannel are null, the response
 * is simply returned as a string, and nothing is sent.
 */
proc _handleCommand(@line, @source, @discordChannel) {
	@line = substr(@line, 1);
	array @commands = array(
		'ping': closure(){ return('pong'); },
		'api': closure(@args) {
			msg(typeof(@args) . ' ' . length(@args) . ' ' . @args);
			if(length(@args) == 1) {
				return("~api <element>");
			}
			string @f = @args[1];
			always_trace(@f);
			@api = _getAPIObject();
			@show = associative_array();
			foreach(@type: @innerAPI in @api) {
				if(!(@type == 'events' || @type == 'functions' || @type == 'keywords' || @type == 'objects')) {
					// Whitelist certain keys
					continue();
				}
				if(array_index_exists(@innerAPI, @f)) {
					@show[@type] = @f;
				}
			}
			array @output = array();
			foreach(@type: @name in @show) {
				@output[] = execute(closure() {
					@value = @api[@type][@f];
					switch(@type) {
						case 'keywords':
							return("@f keyword: " . @value['docs']);
						case 'objects':
							@docs = string(@value['docs']);
							@interfaces = @value['interfaces'];
							@superclasses = @value['superclasses'];
							if(length(@interfaces) > 0) {
								@interfaces = "implements " . array_implode(@interfaces, ', ');
							} else {
								@interfaces = "";
							}
							if(length(@superclasses) > 0) {
								@superclasses = "extends " . array_implode(@superclasses, ', ');
							} else {
								@superclasses = "";
							}
							return(trim("class @f @superclasses @interfaces") . "\n@docs");
						case 'events':
							@desc = @value['desc'];
							@eventData = string(@value['eventData']);
							@mutability = string(@value['mutability']);
							@prefilters = string(@value['prefilters']);
							return("@f\n@desc\nEvent Object: @eventData\nMutable Fields: @mutability\nPrefilters: @prefilters");
						case 'functions':
							@type = @value['ret'];
							@a = @value['args'];
							@description = @value['desc'];
							@ret = "@type @f(@a);\n";
							if(length(@description) > 512) {
								@description = @description[0..512] . '...';
							}
							return(@ret . @description . '\nhttps://methodscript.com/docs/' . extension_info('Core')['version'] . '/API/functions/' . @f . '.html');
					}
				});
			} else {
				return("Could not find anything in the API with that name.");
			}
			if(length(@output) > 1) {
				@preamble = "@f can be found as multiple types of things:\n";
				return(@preamble . array_implode(@output, '\n'));	
			} else {
				return(@output[0]);
			}
		},
		'help': closure(){ return("Current commands: ~ping, ~api <thing>") }
	);
	array @args = parse_args(@line, true);
	if(array_index_exists(@commands, @args[0])) {
		string @ret = execute(@args, @source, @commands[@args[0]]);
		if(@source == null && @discordChannel == null, return(@ret));
		if(@ret != null) {
			if(@discordChannel == null) {
				_broadcastAll(@ret, 'general');
			} else {
				_broadcastDiscord(@ret, @discordChannel);
			}
		}
	} else {
		@notFound = "Could not find command \"@{args[0]}\", try ~help";
		if(@source == null && @discordChannel == null, return(@notFound));
		if(@discordChannel == null) {
			_broadcastAll(@notFound, 'general');
		} else {
			_broadcastDiscord(@notFound, @discordChannel);
		}
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
      string @nick = @event['nickname'];
      string @message = @event['message'];
      if(@event['channel'] == 'general') {
	msg('Discord: ' . @event);
	_broadcastIRC("[D]"._processNick(@nick).": @message");
	if(_isCommand(@message)) {
		_handleCommand(@message, 'discord');
	}
      } else {
        if(_isCommand(@message)) {
           _handleCommand(@message, 'discord', @event['channel']);
        }
      }
    }

	bind('discord_private_message_received', null, null, @event) {
		int @userid = @event['userid'];
		string @username = @event['username'];
		string @message = @event['message'];
		string @resp = _handleCommand(@message, null, null);
		msg("Got message from @userid:@username: @message");
		discord_private_message(@userid, @resp);
	}
  });
});
