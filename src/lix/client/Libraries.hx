package lix.client;

import lix.client.sources.*;
import haxe.DynamicAccess;
import lix.client.Archives;
import lix.api.Api;
import haxeshim.Scope.*;

using sys.FileSystem;
using sys.io.File;

using haxe.Json;

@:tink class Libraries {
  
  public var scope(default, null):Scope = _;
  
  var urlToJob:Url->Promise<ArchiveJob> = _;
  var resolver:Array<Dependency>->Promise<Array<ArchiveJob>> = _;

  public var log(default, null):String->Void = _;
  public var force(default, null):Bool = _;
  public var silent(default, null):Bool = _;
  
  public function downloadUrl(url:Url, ?options) 
    return downloadArchive(urlToJob(url), options);
    
  public function downloadArchive(a:Promise<ArchiveJob>, _ = { into: (null:String) }):Promise<DownloadedArchive>
    return a.next(
      function (a) {
        
        var cacheFile = null;

        if (into == null) 
          switch a.dest {
            case Fixed(path): 
              into = DownloadedArchive.path(path);
            case Computed(_):
              cacheFile = '${scope.libCache}/.cache/libNames/${DownloadedArchive.escape(a.url)}';
              if (cacheFile.exists()) 
                into = cacheFile.getContent();
          }
        
        var exists = into != null && '${scope.libCache}/$into'.exists();
        return 
          if (exists && !force) {
            log('already downloaded: ${a.normalized}');
            DownloadedArchive.existent(into, scope.libCache, a);
          }
          else {
            log('${if (exists) "forcedly redownloading" else "downloading"} ${a.normalized}');
            var dest = scope.haxeshimRoot + '/downloads/download@' + Date.now().getTime();
            (switch a.kind {
              case null: Download.archive(a.url, 0, dest, !silent);
              case Zip: Download.zip(a.url, 0, dest, !silent);
              case Tar: Download.tar(a.url, 0, dest, !silent);
              case Custom(load): 
                load({ dest: dest, silent: silent, source: a.normalized, scope: scope });
            })
              .next(dir => DownloadedArchive.fresh(dir, scope.libCache, into, a))
              .next(arch => {
                if (cacheFile != null) {
                  Fs.ensureDir(cacheFile);
                  cacheFile.saveContent(arch.relRoot);
                }
                arch;
              });
          }
      }
    );     

  public function installUrl(url:Url, ?as:LibVersion, ?options):Promise<Noise> 
    return installArchive(urlToJob(url), as, options);

  function installFromLibHxml(lib:String, srcPath:String):Promise<Noise>
    return Fs.copy(srcPath, '${scope.scopeLibDir}/$lib.hxml')
      .next(_ -> scope.getDirectives(lib))
      .next(d -> switch d['install'] {
        case null | []: 
          new Error('No install directive in $srcPath');
        case directives: 
          Promise.inSequence([for (d in directives) 
            Promise.NOISE.next(_ -> {
              if (!silent) log(d);
              Exec.shell(d, scope.scopeDir);
            })
          ]);
      });
    
  public function installArchive(a:Promise<ArchiveJob>, ?as:LibVersion, options = { alreadyInstalled: new Map() }):Promise<Noise> 
    return downloadArchive(a).next(function (a) {
      var extra =
        switch '${a.absRoot}/extraParams.hxml' {
          case found if (found.exists()):
            found.getContent();
          default: '';
        }
      
      if (as == null)
        as = { name: None, version: None };

      var infos:ArchiveInfos = a.infos;
      
      var name = as.name.or(infos.name),
          version = as.version.or(infos.version);

      if (name == null)
        return new Error('Could not determine library name for ${a.job.normalized}');

      var hxml = Resolver.libHxml(scope.scopeLibDir, name);
      
      Fs.ensureDir(hxml);

      log('mounting as $name#$version');  

      var DOWNLOAD_LOCATION = '$${$LIBCACHE}/${a.relRoot}';

      function interpolate(s:String)
        return Resolver.interpolate(s, switch _ {
          case 'DOWNLOAD_LOCATION': DOWNLOAD_LOCATION;
          default: null;  
        });

      function exec(hook:String, cmd:Null<String>, ?cwd:String):Promise<Noise>
        return 
          if (cmd != null) {
            
            cmd = scope.interpolate(interpolate(cmd));//TODO: this is a mess

            if (cwd == null)
              cwd = scope.cwd;

            log('Running $hook hook:');
            log('> $cmd');

            Exec.shell(
              cmd, 
              scope.interpolate(cwd), 
              scope.haxeInstallation.env()
            ).map(_ => Noise);
          }
          else
            Noise;

      function saveHxml<T>(?value:T):Promise<T> 
        return (function () {
          var directives = [
            '-D $name=$version',
            '# @$INSTALL: lix --silent download "${a.job.normalized}" into ${a.relRoot}',            
          ];

          switch infos.postDownload {
            case null:
            case v: directives.push('# @$POST_INSTALL: cd $DOWNLOAD_LOCATION && ${interpolate(v)}');
          }

          switch infos.runAs({ libRoot: scope.interpolate(DOWNLOAD_LOCATION) }) {
            case None:
            case Some(v): directives.push('# @run: ${interpolate(v)}');
          }

          hxml.saveContent(
            directives
              .concat([for (lib in infos.dependencies) '-lib ${lib.name}'])
              .concat([
                '-cp $DOWNLOAD_LOCATION/${infos.classPath}',
                extra,
              ]).join('\n')
          );

          return value;
        }).catchExceptions();

      saveHxml();

      options.alreadyInstalled[name] = true;

      return 
        Future.ofMany(//TODO: this relies on the implementation being sequential (which it currently is, but that may change)
          [for ({ name: lib, value: dep } in infos.dependencies) 
            Future.async(//TODO: it should probably be fine to skip this lazy wrapper
              function (done) 
                if ('${scope.scopeLibDir}/$lib.hxml'.exists() && options.alreadyInstalled[lib]) //TODO: this should be in some function
                  done(Success(Noise))
                else switch dep {
                  case FromUrl(url):
                    installUrl(url, { name: Some(lib), version: None }, options).handle(done);
                  case FromHxml(content): 
                    installFromLibHxml(lib, content)
                      .next(_ -> { options.alreadyInstalled[lib] = true; Noise; })
                      .handle(done);
                },
              true
            )
          ]
        )
        .next(results => switch [for (Failure(e) in results) e] {
          case []: Noise;
          case errors: Error.withData('Failed to install dependencies:\n  ' + errors.map(e => e.message).join('\n  '), errors);
        })
        .next(_ => 
          if (!a.alreadyDownloaded) exec('post download', infos.postDownload, DOWNLOAD_LOCATION)
          else Noise
        ).next(saveHxml).next(_ => exec('post install', infos.postInstall));
    });  
}