# nginx http 子请求

现有的模块只能处理一种请求、完成一个任务，而对于需要多个请求协同完成的任务则无能为力。当然，这种任务可以由客户端发起多个请求来完成，但是这样加重了客户端的负担，效率也得不到保证，所以 nginx 提出了子请求机制。

由客户端发起的 HTTP 请求被称为主请求，它直接与客户端通信；而子请求是 nginx 内部发起的特殊 HTTP 请求，由于已经处于 nginx 内部，所以它不需要与客户端建立连接，也不需要解析请求行、请求头等等。

子请求结构上和普通的 HTTP 请求一样，只不过多了从属关系，所以也是用`ngx_http_request_t`表示，其中与子请求有关的几个字段：

> 在 Nginx 世界里有两种类型的“请求”，一种叫做“主请求”（main request），而另一种则叫做“子请求”（subrequest）。我们先来介绍一下它们。
> 所谓“主请求”，就是由 HTTP 客户端从 Nginx 外部发起的请求。我们前面见到的所有例子都只涉及到“主请求”，包括 （二） 中那两个使用 echo_exec 和 rewrite 指令发起“内部跳转”的例子。
> 而“子请求”则是由 Nginx 正在处理的请求在 Nginx 内部发起的一种级联请求。“子请求”在外观上很像 HTTP 请求，但实现上却和 HTTP 协议乃至网络通信一点儿关系都没有。它是 Nginx 内部的一种抽象调用，目的是为了方便用户把“主请求”的任务分解为多个较小粒度的“内部请求”，并发或串行地访问多个 location 接口，然后由这些 location 接口通力协作，共同完成整个“主请求”。当然，“子请求”的概念是相对的，任何一个“子请求”也可以再发起更多的“子子请求”，甚至可以玩递归调用（即自己调用自己）。当一个请求发起一个“子请求”的时候，按照 Nginx 的术语，习惯把前者称为后者的“父请求”（parent request）。值得一提的是，Apache 服务器中其实也有“子请求”的概念，所以来自 Apache 世界的读者对此应当不会感到陌生。

```c
struct ngx_http_request_s {
    ...
    
    ngx_http_request_t               *main;
    ngx_http_request_t               *parent;
    ngx_http_postponed_request_t     *postponed;
    ngx_http_post_subrequest_t       *post_subrequest;
    ngx_http_posted_request_t        *posted_requests;
    
    ...
};


typedef struct {
    ngx_http_post_subrequest_pt       handler;
    void                             *data;
} ngx_http_post_subrequest_t;


typedef struct ngx_http_postponed_request_s  ngx_http_postponed_request_t;

struct ngx_http_postponed_request_s {
    ngx_http_request_t               *request;
    ngx_chain_t                      *out;
    ngx_http_postponed_request_t     *next;
};


typedef struct ngx_http_posted_request_s  ngx_http_posted_request_t;

struct ngx_http_posted_request_s {
    ngx_http_request_t               *request;
    ngx_http_posted_request_t        *next;
};
```

* `main`就是指出主请求，`parent`则是指出父请求，这两者并不是等价的，主请求是一个绝对概念，它只有一个，而父请求是一个相对概念，可以有多个。
* `postponed` 
* `post_subrequest`表示的是该子请求结束后的回调方法，以及该回调方法的参数。
* `posted_requests`


## 子请求的创建

子请求通过`ngx_http_subrequest`函数创建，这个函数比较长，分段来看一下：

```c
ngx_int_t
ngx_http_subrequest(ngx_http_request_t *r,
    ngx_str_t *uri, ngx_str_t *args, ngx_http_request_t **srp,
    ngx_http_post_subrequest_t *psr, ngx_uint_t flags)
{
    ngx_time_t                    *tp;
    ngx_connection_t              *c;
    ngx_http_request_t            *sr;
    ngx_http_core_srv_conf_t      *cscf;
    ngx_http_postponed_request_t  *pr, *p;

    if (r->subrequests == 0) {
        ...
        return NGX_ERROR;
    }

    if (r->main->count >= 65535 - 1000) {
        ...
        return NGX_ERROR;
    }

    if (r->subrequest_in_memory) {
        ...
        return NGX_ERROR;
    }
```

首先是函数签名，参数还挺多：

* `r`：父请求
* `uri`：子请求的 uri，用于决定访问哪个 location{}
* `args`：子请求的参数，这个不是必需的
* `srp`：子请求的指针，是一个结果参数
* `psr`：子请求结束时的回调方法以及该回调的参数
* `flags`：用于设置子请求的一些属性

函数首先是判断是否可以创建子请求，nginx 对此有 3 个要求（依次对应 3 个`if`判断）：

* 请求树的层级不得超过 51 层
* 请求树中节点个数不得超过 64535(其实`r->main->count`不是表示请求树中的节点个数，而只是对主请求的引用数，恰好每创建一个子请求也会将该引用数递增 1，其实也存在非创建子请求的场景(发起异步操作)也递增该引用；主要是为了防止主请求在异步操作完成之前就被销毁了)
* `subrequest_in_memory`置位的请求不得再创建子请求(TODO: 这个是为什么？)

```c
    sr = ngx_pcalloc(r->pool, sizeof(ngx_http_request_t));
    if (sr == NULL) {
        return NGX_ERROR;
    }

    sr->signature = NGX_HTTP_MODULE;

    c = r->connection;
    sr->connection = c;

    cscf = ngx_http_get_module_srv_conf(r, ngx_http_core_module);
    sr->main_conf = cscf->ctx->main_conf;
    sr->srv_conf = cscf->ctx->srv_conf;
    sr->loc_conf = cscf->ctx->loc_conf;

    sr->pool = r->pool;

    sr->method = NGX_HTTP_GET;
    sr->request_line = r->request_line;
    sr->uri = *uri;

    if (args) {
        sr->args = *args;
    }

    sr->subrequest_in_memory = (flags & NGX_HTTP_SUBREQUEST_IN_MEMORY) != 0;
    sr->waited = (flags & NGX_HTTP_SUBREQUEST_WAITED) != 0;
    sr->background = (flags & NGX_HTTP_SUBREQUEST_BACKGROUND) != 0;
```

接下来就是设置`ngx_http_request_t`中的一些字段了，其中有几点值得关注：

* 子请求和父请求共享内存池，这就说明，在子请求结束时，其分配的数据在父请求中还是可以访问的
* 子请求默认的 HTTP 方法为 GET，但是我们可以在函数外部对其进行修改
* 子请求不能跨 server{}，这是因为子请求并不涉及
* 

```c
    sr->main = r->main;
    sr->parent = r;
    sr->post_subrequest = ps;
    sr->read_event_handler = ngx_http_request_empty_handler;
    sr->write_event_handler = ngx_http_handler;

    sr->variables = r->variables;

    sr->log_handler = r->log_handler;

    if (sr->subrequest_in_memory) {
        sr->filter_need_in_memory = 1;
    }

```

为该子请求设置其主请求、父请求以及子请求结束后的回调方法。

默认产生的 subrequest 的 read_event_handler 是 dummy，因为 subrequest 不需要从从 client 读取数据（如果用于是 upstream 的话，因为还没有发送请求至 upstream，所以也不用读），write_event_handler 是 ngx_http_handler，在`ngx_http_handler`函数中， 由于子请求都带有`internal`标志位（在下面代码中设置），所以默认从 SERVER_REWRITE 阶段开始执行（这个阶段在将请求的 URI 与 location 匹配之前，修改请求的 URI，即重定向），并将`write_event_handler`重新设置为`ngx_http_core_run_phases`并执行该函数

```c
    if (!sr->background) {

        if (c->data == r && r->postponed == NULL) {
            c->data = sr;
        }

        pr = ngx_palloc(r->pool, sizeof(ngx_http_postponed_request_t));
        if (pr == NULL) {
            return NGX_ERROR;
        }

        pr->request = sr;
        pr->out = NULL;
        pr->next = NULL;

        if (r->postponed) {
            for (p = r->postponed; p->next; p = p->next) { /* void */ }
            p->next = pr;

        } else {
            r->postponed = pr;
        }
    }
```

这一块代码涉及到与其他请求的交互，比较难理解。

具有`background`属性子请求用在缓存中，这里暂且略去不讲。如果不是后台子请求（后台子请求不参与数据的产出），那么会将该子请求挂载在其父请求的`postponed`（这个词的意思是"延期的"）链表末尾。这里需要注意子请求完成的顺序和发起的顺序不一定相同，由于需要完成的任务不同，可能后发起的子请求先完成了，为了正确组织子请求返回的数据，nginx 使用`postponed`链表来组织本级请求发起的所有子请求：

```c
typedef struct ngx_http_postponed_request_s  ngx_http_postponed_request_t;

struct ngx_http_postponed_request_s {
    ngx_http_request_t               *request;
    ngx_chain_t                      *out;
    ngx_http_postponed_request_t     *next;
};
```

可以看到里面有`ngx_http_request_t`，还有一个`ngx_chain_t`，这俩字段是互斥的，也就是说，一个 postponed 节点要么是请求节点，要么是数据节点。将子请求挂载在其父请求的`postponed`链表中表示一种延后处理的思想，此时子请求并不会立即开始执行，而是等待 HTTP 引擎调度。父请求在调用`ngx_http_subrequest`创建子请求后，必须返回`NGX_DONE`告诉 HTTP 框架

上面还有一个关于`c->data`的逻辑，这里需要注意；当前正在执行的请求被称为活跃请求(current active request, CAR)，活跃请求被存储在该请求的连接的`data`字段中，

* 子请求的数据要在父请求之前发送出去
* 子请求之间的响应数据发送顺序为创建的顺序
* 活跃请求的产生的响应数据可以立即发送出去(TODO: 这个还不太理解)

所以，如果父请求为活跃请求，且新创建的子请求为其第一个子请求，那么根据以上 3 条规则，需要把该子请求设置为活跃请求。

```c
    sr->internal = 1;
    sr->subrequests = sr->subrequests - 1;
    r->main->count++;

    *srp = sr;

    if (flags & NGX_HTTP_SUBREQUEST_CLONE) {
        ...
    }

    return ngx_http_post_request(sr, NULL);
}
```

最后调用`ngx_http_post_requesot`函数将新创建的子请求挂载到**主请求**的`posted_requests`链表的末尾，这个链表用以保存需要延迟处理的请求(不局限于子请求)。因此子请求会在父请求本地调度完毕后得到运行的机会，这通常是子请求获得首次运行机会的手段。

## 调度子请求运行

子请求是在`ngx_http_run_posted_request`中被调度执行的：

```c
void
ngx_http_run_posted_requests(ngx_connection_t *c)
{
    ngx_http_request_t         *r;
    ngx_http_posted_request_t  *pr;

    for ( ;; ) {

        if (c->destroyed) {
            return;
        }

        r = c->data;
        pr = r->main->posted_requests;

        if (pr == NULL) {
            return;
        }

        r->main->posted_requests = pr->next;

        r = pr->request;

        ngx_http_set_log_request(c->log, r);

        r->write_event_handler(r);
    }
}
```

比较简单，就是将主请求的`posted_requests`链表上的子请求的`write_event_handler`都执行一遍。

QUESTION: 上面的代码中将 posted 链表向前移动了一个位置，然后执行该首节点表示的子请求，如果此时子请求还没有执行完(因为网络原因而被挂起了)，那么下一轮该怎么继续保持住子请求之间的顺序呢？
其实是这样的，一来 main request 的`posted_requests`并不是用来保存请求之间的依赖关系的，而且它仅仅是个单链表根本没法保存，子请求(以及孙子...)之间的依赖关系其实是由`r->postponed`链表以及`postponed_request->next`这两个链表组成的树来维护的，而子请求树只有当子请求轮到他(it's my time, 只子请求数据的发送顺序)他才会被从树中摘除(所以不用担心保持不了子请求之间的顺序)；而`posted_requests`只是为了便于调度执行(遍历链表总是简单的)；会不会发生被移除出 post 链表但是子请求没有执行完的情况导致无法被继续执行的情况呢？其实也不会，因为后续如果该子请求产生的数据被缓存了，它还是会被加入到该链表。

## 结束子请求 & 激活父请求

子请求处理完成后，如何结束子请求，以及子请求结束后如何激活父请求呢？在 nginx 中，我们通过`ngx_http_finalize_request`函数结束请求，而如果该请求是子请求，则会...

```c
void
ngx_http_finalize_request(ngx_http_request_t *r, ngx_int_t rc)
{
    ...
    if (r != r->main && r->post_subrequest) {
        r->post_subrequest->handler(r->post_subreuqest->data, rc);
    }
```

首先如果这个请求是一个子请求，那么检查`post_subrequest`，这个回调是在创建子请求的时候设置的，需要在子请求结束时被调用，此时正是其调用时机。

```c
    ...
    if (r != r->main) {
        
        if (r->backgroud) {
            r->done = 1;
            ngx_http_finalize_connection(r);
            return;
        }
        
        if (r->buffered || r->postponed) {
            
            if (ngx_http_set_write_handler(r) != NGX_OK) {
                ngx_http_terminalte_request(r, 0);
            }
            
            return;
        }
```

如果这是一个后台子请求的话，由于它没有 postponed 逻辑，所以我们直接将其设置为完成(`r->done`的用途?)然后结束请求(`ngx_http_finalize_connection`函数具体做了什么)。
否则的话，我们就得处理其 postponed 逻辑了；如果这个请求的数据尚未发送完毕(`c->buffered == 1`)，或者该请求创建的子子请求还没有完成(`r->postponed != NULL`，也有可能是有数据节点还没有发送完毕)，由于子请求的数据需要在父请求之前发送，所以(TODO: `ngx_http_set_write_handler`逻辑还比较复杂，会进行实际数据的发送么？)

```c
        pr = r->parent;
        if (r == c->data) {
            r->main->count--;
            
            r->done = 1;
            
            if (pr->postponed && pr->postponed->request == r) {
                pr->postponed = pr->postponed->next;
            }
            
            c->data = pr;
            
        } else {
            r->write_event_handler = ngx_http_request_finalizer;
            
            if (r->waited) {
                r->done = 1;
            }
        }
        
```

如果被处理的请求是当前活跃请求(而且经过之前的逻辑表示它没有子请求)，那么

```c
        if (ngx_http_post_reqeuest(pr, NULL) != NGX_OK) {
            r->main->count++;
            ngx_http_terminate_request(r, 0);
            return;
        }
        
        return;
    }
}
```

## 数据组装

子请求数据组装主要在`ngx_http_postpone_filter_module`中。

## 总结

子请求比较难懂，对此我有以下几点理解：

* `posted_requests`只在主请求中有效，它将所有的子请求（以及孙子请求等）都聚集在一个单链表中，是为了便于将子请求调度执行（方便的原因有两个，一个是主请求容易找到，二是单链表结构简单容易遍历）
* `postponed`链表散落在各个请求中，从而形成树状结构（请求树），这是为了有序组织各个请求的响应数据，从而可以将其有序发送给客户端

## 参考

- [nginx 子请求设计之道](https://zhuanlan.zhihu.com/p/36595828)
- [nginx 子请求并发处理](https://blog.csdn.net/ApeLife/article/details/75003346)
- [nginx http 子请求笔记](https://ialloc.org/blog/ngx-notes-http-subrequest/)
- [看云: subrequest 原理解析](https://www.kancloud.cn/kancloud/master-nginx-develop/51853)
- [nginx subrequest 的实现解析](https://blog.csdn.net/fengmo_q/article/details/6685840)
- [postpone filter 模块源码剖析](https://github.com/y123456yz/reading-code-of-nginx-1.9.2/blob/master/nginx-1.9.2/src/http/ngx_http_postpone_filter_module.c)