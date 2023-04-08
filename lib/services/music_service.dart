import 'dart:convert';
import 'dart:developer';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:get/get.dart' as getx;
import 'package:harmonymusic/services/utils.dart';
import 'package:hive/hive.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../helper.dart';
import 'constant.dart';
import 'continuations.dart';
import 'nav_parser.dart';

// ignore: constant_identifier_names
enum AudioQuality { High, Medium, Low }

class MusicServices extends getx.GetxService {
  late YoutubeExplode _yt;
  MusicServices(bool isMain) {
    if (isMain) {
      init();
    } else {
      _yt = YoutubeExplode();
    }
  }

  final Map<String, String> _headers = {
    'user-agent': userAgent,
    'accept': '*/*',
    'accept-encoding': 'gzip, deflate',
    'content-type': 'application/json',
    'content-encoding': 'gzip',
    'origin': domain,
    'cookie': 'CONSENT=YES+1',
  };

  final Map<String, dynamic> _context = {
    'context': {
      'client': {
        "clientName": "WEB_REMIX",
        "clientVersion": "1.20230213.01.00",
      },
      'user': {}
    }
  };

  final dio = Dio();

  Future<void> init() async {
    print("ibit");
    //check visitor id in data base, if not generate one , set lang code
    _context['context']['client']['hl'] = 'en';
    _context['context']['client']['gl'] = 'IN';
    final signatureTimestamp = getDatestamp() - 1;
    _context['playbackContext'] = {
      'contentPlaybackContext': {'signatureTimestamp': signatureTimestamp},
    };
    _headers['X-Goog-Visitor-Id'] = 'CgszaE1mUm55NHNwayjXiamfBg%3D%3D';
    _yt = YoutubeExplode();
    final appPrefsBox = Hive.box('AppPrefs');
    if (appPrefsBox.containsKey('visitorId')) {
      final visitorData = appPrefsBox.get("visitorId");
      if (!isExpired(epoch: visitorData['exp'])) {
        _headers['X-Goog-Visitor-Id'] = visitorData['id'];
        appPrefsBox.put("visitorId", {
          'id': visitorData['id'],
          'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2590200
        });
        printINFO("Got Visitor id ($visitorData['id']) from Box");
        return;
      }
    }
    var visitorId = await genrateVisitorId();
    if (visitorId != null) {
      _headers['X-Goog-Visitor-Id'] = visitorId;
      printINFO("New Visitor id generated ($visitorId)");
    } else {
      visitorId = await genrateVisitorId();
    }
    appPrefsBox.put("visitorId", {
      'id': visitorId,
      'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2592000
    });
  }

  Future<String?> genrateVisitorId() async {
    try {
      final response =
          await dio.get(domain, options: Options(headers: _headers));
      final reg = RegExp(r'ytcfg\.set\s*\(\s*({.+?})\s*\)\s*;');
      final matches = reg.firstMatch(response.data.toString());
      String? visitorId;
      if (matches != null) {
        final ytcfg = json.decode(matches.group(1).toString());
        visitorId = ytcfg['VISITOR_DATA']?.toString();
      }
      return visitorId;
    } catch (e) {
      return null;
    }
  }

  Future<Response> _sendRequest(String action, Map<dynamic, dynamic> data,
      {additionalParams = ""}) async {
    //print("$baseUrl$action$fixedParms$additionalParams          data:$data");
    final response =
        await dio.post("$baseUrl$action$fixedParms$additionalParams",
            options: Options(
              headers: _headers,
            ),
            data: data);

    if (response.statusCode == 200) {
      return response;
    } else {
      return _sendRequest(action, data, additionalParams: additionalParams);
    }
  }

  // Future<List<Map<String, dynamic>>>
  Future<dynamic> getHome({int limit = 4}) async {
    final data = Map.from(_context);
    data["browseId"] = "FEmusic_home";
    final response = await _sendRequest("browse", data);
    final results = nav(response.data, single_column_tab + section_list);
    final home = [...parseMixedContent(results)];

    final sectionList =
        nav(response.data, single_column_tab + ['sectionListRenderer']);
    //inspect(sectionList);
    //print(sectionList.containsKey('continuations'));
    if (sectionList.containsKey('continuations')) {
      requestFunc(additionalParams) async {
        return (await _sendRequest("browse", data,
                additionalParams: additionalParams))
            .data;
      }

      parseFunc(contents) => parseMixedContent(contents);
      final x = (await getContinuations(sectionList, 'sectionListContinuation',
          limit - home.length, requestFunc, parseFunc));
      // inspect(x);
      home.addAll([...x]);
    }

    return home;
  }

  Future<Map<String, dynamic>> getWatchPlaylist({
    String videoId = "",
    String playlistId = "",
    int limit = 25,
    bool radio = false,
    bool shuffle = false,
  }) async {
    final data = Map.from(_context);
    data['enablePersistentPlaylistPanel'] = true;
    data['isAudioOnly'] = true;
    data['tunerSettingValue'] = 'AUTOMIX_SETTING_NORMAL';
    if (videoId == "" && playlistId == "") {
      throw Exception(
          "You must provide either a video id, a playlist id, or both");
    }
    if (videoId != "") {
      data['videoId'] = videoId;
      if (playlistId == "") {
        playlistId = "RDAMVM$videoId";
      }

      if (!(radio || shuffle)) {
        data['watchEndpointMusicSupportedConfigs'] = {
          'watchEndpointMusicConfig': {
            'hasPersistentPlaylistPanel': true,
            'musicVideoType': "MUSIC_VIDEO_TYPE_ATV",
          }
        };
      }
    }

    playlistId = validatePlaylistId(playlistId);
    data['playlistId'] = playlistId;
    final isPlaylist =
        playlistId.startsWith('PL') || playlistId.startsWith('OLA');
    if (shuffle) {
      data['params'] = "wAEB8gECKAE%3D";
    }
    if (radio) {
      data['params'] = "wAEB";
    }
    final response = (await _sendRequest("next", data)).data;
    inspect(response);
    final watchNextRenderer = nav(response, [
      'contents',
      'singleColumnMusicWatchNextResultsRenderer',
      'tabbedRenderer',
      'watchNextTabbedResultsRenderer'
    ]);

    final lyricsBrowseId = getTabBrowseId(watchNextRenderer, 1);
    final relatedBrowseId = getTabBrowseId(watchNextRenderer, 2);

    final results = nav(watchNextRenderer, [
      ...tab_content,
      'musicQueueRenderer',
      'content',
      'playlistPanelRenderer'
    ]);
    final playlist = results['contents']
        .map((content) => nav(
            content, ['playlistPanelVideoRenderer', ...navigation_playlist_id]))
        .where((e) => e != null)
        .toList()
        .first;
    final tracks = parseWatchPlaylist(results['contents']);

    // if (results.containsKey('continuations')) {
    //   requestFunc(additionalParams) async =>
    //       (await _sendRequest("next", data, additionalParams: additionalParams))
    //           .data;
    //   parseFunc(contents) => parseWatchPlaylist(contents);
    //   final x = await getContinuations(results, 'playlistPanelContinuation',
    //       limit - tracks.length, requestFunc, parseFunc,
    //       ctokenPath: isPlaylist ? '' : 'Radio');
    //   tracks.addAll([...x]);
    // }

    return {
      'tracks': tracks,
      'playlistId': playlist,
      'lyrics': lyricsBrowseId,
      'related': relatedBrowseId
    };
  }

  Future<Map<String, dynamic>> getPlaylistOrAlbumSongs(
      {String? playlistId,
      String? albumId,
      int limit = 100,
      bool related = false,
      int suggestionsLimit = 0}) async {
    String browseId = playlistId != null
        ? (playlistId.startsWith("VL") ? playlistId : "VL$playlistId")
        : albumId!;
    final data = Map.from(_context);
    data['browseId'] = browseId;
    Map<String, dynamic> response = (await _sendRequest('browse', data)).data;
    if (playlistId != null) {
      Map<String, dynamic> header = response['header'];
      Map<String, dynamic> results = nav(
          response,
          single_column_tab +
              section_list_item +
              ['musicPlaylistShelfRenderer']);
      Map<String, dynamic> playlist = {'id': results['playlistId']};

      bool ownPlaylist =
          header.containsKey('musicEditablePlaylistDetailHeaderRenderer');
      if (!ownPlaylist) {
        playlist['privacy'] = 'PUBLIC';
        header = header['musicDetailHeaderRenderer'];
      } else {
        Map<String, dynamic> editableHeader =
            header['musicEditablePlaylistDetailHeaderRenderer'];
        playlist['privacy'] = editableHeader['editHeader']
            ['musicPlaylistEditHeaderRenderer']['privacy'];
        header = editableHeader['header']['musicDetailHeaderRenderer'];
      }

      playlist['title'] = nav(header, title_text);
      playlist['thumbnails'] = nav(header, thumnail_cropped);
      playlist["description"] = nav(header, description);
      int runCount = header['subtitle']['runs'].length;
      if (runCount > 1) {
        playlist['author'] = {
          'name': nav(header, subtitle2),
          'id': nav(header, ['subtitle', 'runs', 2] + navigation_browse_id)
        };
        if (runCount == 5) {
          playlist['year'] = nav(header, subtitle3);
        }
      }

      int songCount = int.parse(RegExp(r'([\d,]+)')
          .stringMatch(header['secondSubtitle']['runs'][0]['text'])!);
      if (header['secondSubtitle']['runs'].length > 1) {
        playlist['duration'] = header['secondSubtitle']['runs'][2]['text'];
      }
      playlist['trackCount'] = songCount;

      requestFunc(additionalParams) async => (await _sendRequest("browse", data,
              additionalParams: additionalParams))
          .data;

      if (songCount > 0) {
        playlist['tracks'] = parsePlaylistItems(results['contents']);
        limit = songCount;
        var songsToGet = min(limit, songCount);

        List<dynamic> parseFunc(contents) => parsePlaylistItems(contents);
        if (results.containsKey('continuations')) {
          (playlist['tracks'] as List<dynamic>).addAll(await getContinuations(
              results,
              'musicPlaylistShelfContinuation',
              songsToGet - (playlist['tracks']).length as int,
              requestFunc,
              parseFunc));
        }
      }
      playlist['duration_seconds'] = sumTotalDuration(playlist);
      return playlist;
    }

    //album content
    final album = parseAlbumHeader(response);
    dynamic results = nav(
      response,
      [...single_column_tab, ...section_list_item, 'musicShelfRenderer'],
    );
    album['tracks'] = parsePlaylistItems(results['contents'],
        artistsM: album['artists'], thumbnailsM: album["thumbnails"]);
    results = nav(
      response,
      [...single_column_tab, ...section_list, 1, 'musicCarouselShelfRenderer'],
    );
    if (results != null) {
      List contents = [];
      for (dynamic result in results) {
        contents.add(parseAlbum(result['musicTwoRowItemRenderer']));
      }
      album['other_versions'] = contents;
    }
    album['duration_seconds'] = sumTotalDuration(album);

    return album;
  }

  Future<List<String>> getSearchSuggestion(String queryStr) async {
    final data = Map.from(_context);
    data['input'] = queryStr;
    final res = nav(
            (await _sendRequest("music/get_search_suggestions", data)).data,
            ['contents', 0, 'searchSuggestionsSectionRenderer', 'contents']) ??
        [];
    return res
        .map<String?>((item) {
          return (nav(item, [
            'searchSuggestionRenderer',
            'navigationEndpoint',
            'searchEndpoint',
            'query'
          ])).toString();
        })
        .whereType<String>()
        .toList();
  }

  Future<Uri?> getSongUri(String songId,
      {AudioQuality quality = AudioQuality.High}) async {
    try {
      final songStreamManifest =
          await _yt.videos.streamsClient.getManifest(songId);
      final streamUriList = songStreamManifest.audioOnly.sortByBitrate();
      final high = streamUriList.firstWhere((element) => element.audioCodec.contains("mp4a")).url;
      printINFO(high.toString());
      if (quality == AudioQuality.High && high!=null) {
        return high;
        
      } else if (quality == AudioQuality.Medium) {
        return streamUriList[streamUriList.length ~/ 2].url;
      } else {
        return streamUriList.lastWhere((element) => element.audioCodec.contains("mp4a")).url;
      }
    } catch (e) {
      return null;
    }
  }

//  Future<Uri> getSongUri(String songId) async {
//     final response =
//         await Dio().get("https://watchapi.whatever.social/streams/$songId");
//     if (response.statusCode == 200) {
//       final responseUrl = ((response.data["audioStreams"])
//           .firstWhere((val) => val["quality"] == "48 kbps"))["url"];
//           print("hello");
//       return Uri.parse(responseUrl);
//     } else {
//       return getSongUri(songId);
//     }
//   }

  Future<Map<String, dynamic>> search(String query,
      {String? filter,
      String? scope,
      int limit = 30,
      bool ignoreSpelling = false}) async {
    final data = Map.of(_context);
    data['query'] = query;

    final Map<String, dynamic> searchResults = {};
    final filters = [
      'albums',
      'artists',
      'playlists',
      'community_playlists',
      'featured_playlists',
      'songs',
      'videos'
    ];

    if (filter != null && !filters.contains(filter)) {
      throw Exception(
          'Invalid filter provided. Please use one of the following filters or leave out the parameter: ${filters.join(', ')}');
    }

    final scopes = ['library', 'uploads'];

    if (scope != null && !scopes.contains(scope)) {
      throw Exception(
          'Invalid scope provided. Please use one of the following scopes or leave out the parameter: ${scopes.join(', ')}');
    }

    if (scope == scopes[1] && filter != null) {
      throw Exception(
          'No filter can be set when searching uploads. Please unset the filter parameter when scope is set to uploads.');
    }

    final params = getSearchParams(filter, scope, ignoreSpelling);

    if (params != null) {
      data['params'] = params;
    }

    final response = (await _sendRequest("search", data)).data;

    if (response['contents'] == null) {
      return searchResults;
    }

    dynamic results;

    if ((response['contents']).containsKey('tabbedSearchResultsRenderer')) {
      final tabIndex =
          scope == null || filter != null ? 0 : scopes.indexOf(scope) + 1;
      results = response['contents']['tabbedSearchResultsRenderer']['tabs']
          [tabIndex]['tabRenderer']['content'];
    } else {
      results = response['contents'];
    }

    results = nav(results, ['sectionListRenderer', 'contents']);

    if (results.length == 1 && results[0]['itemSectionRenderer'] != null) {
      return searchResults;
    }

    String? type;

    for (var res in results) {
      String category;
      if (res.containsKey('musicCardShelfRenderer')) {
        //final topResult = parseTopResult(res['musicCardShelfRenderer'], ['artist', 'playlist', 'song', 'video', 'station']);
        //searchResults.add(topResult);
        results = nav(res, ['musicCardShelfRenderer', 'contents']);
        if (results != null) {
          category = nav(results[0], ['messageRenderer', ...text_run_text]);
          results = results.sublist(1);
          //type = null;
        } else {
          continue;
        }
        continue;
      } else if (res['musicShelfRenderer'] != null) {
        results = res['musicShelfRenderer']['contents'];
        var typeFilter = filter;

        category = nav(res, ['musicShelfRenderer', ...title_text]);

        if (typeFilter == null && scope == scopes[0]) {
          typeFilter = category;
        }

        type = typeFilter?.substring(0, typeFilter.length - 1).toLowerCase();
      } else {
        continue;
      }

      searchResults[category] = parseSearchResults(results,
          ['artist', 'playlist', 'song', 'video', 'station'], type, category);

      if (filter != null) {
        requestFunc(additionalParams) async =>
            (await _sendRequest("search", data,
                    additionalParams: additionalParams))
                .data;
        parseFunc(contents) => parseSearchResults(contents,
            ['artist', 'playlist', 'song', 'video', 'station'], type, category);

        if (searchResults.containsKey(category)) {
          searchResults[category] = [
            ...(searchResults[category] as List),
            ...(await getContinuations(
                res['musicShelfRenderer'],
                'musicShelfContinuation',
                limit - ((searchResults[category] as List).length),
                requestFunc,
                parseFunc))
          ];
        }
      }
    }

    return searchResults;
  }
}
